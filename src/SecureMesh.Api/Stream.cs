using System.Net.WebSockets;
using System.Security.Cryptography;
using Google.Protobuf;
using Npgsql;
using SecureMesh.Contracts.Transport.V1;

namespace SecureMesh;

public static class StreamTransport
{
    private const int MaxFrame=131072;
    public static void MapStream(this WebApplication app)
    {
        app.UseWebSockets(new WebSocketOptions {KeepAliveInterval=TimeSpan.FromSeconds(30)});
        app.Map("/v1/stream",async(HttpContext ctx,NpgsqlDataSource db,Delivery delivery)=>
        {
            await Sql.Authenticate(ctx,db);
            if(!ctx.WebSockets.IsWebSocketRequest) {ctx.Response.StatusCode=426;return;}
            using var ws=await ctx.WebSockets.AcceptWebSocketAsync();
            var buffer=new byte[MaxFrame+5]; bool negotiated=false;
            try
            {
                while(ws.State==WebSocketState.Open && !ctx.RequestAborted.IsCancellationRequested)
                {
                    using var timeout=CancellationTokenSource.CreateLinkedTokenSource(ctx.RequestAborted);
                    timeout.CancelAfter(TimeSpan.FromSeconds(45));
                    var count=0;
                    ValueWebSocketReceiveResult result;
                    do
                    {
                        if(count==buffer.Length) throw new ApiError(413,"FRAME_TOO_LARGE");
                        result=await ws.ReceiveAsync(buffer.AsMemory(count),timeout.Token);
                        if(result.MessageType==WebSocketMessageType.Close) {await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure,"closed",CancellationToken.None);return;}
                        if(result.MessageType!=WebSocketMessageType.Binary) throw new ApiError(400,"BINARY_REQUIRED");
                        count+=result.Count;
                    } while(!result.EndOfMessage);
                    Frame request;
                    using(var input=new CodedInputStream(buffer,0,count))
                    {
                        var length=input.ReadLength();
                        if(length is <1 or >MaxFrame || length!=count-input.Position) throw new ApiError(400,"INVALID_FRAME_LENGTH");
                        request=Frame.Parser.ParseFrom(buffer,(int)input.Position,length);
                    }
                    Frame response;
                    try
                    {
                        var actor=await Sql.Authenticate(ctx,db); // re-check expiry and revocation on every frame.
                        if(request.ProtocolVersion!=1 || request.RequestId.Length>32) throw new ApiError(400,"PROTOCOL_VERSION");
                        response=new Frame {ProtocolVersion=1,RequestId=request.RequestId};
                        if(request.Kind==FrameKind.Hello && request.Hello is not null)
                        {
                            if(!request.Hello.SupportedVersions.Contains(1) || Id(request.Hello.ClientDeviceId)!=actor.DeviceId) throw new ApiError(400,"INVALID_HELLO");
                            negotiated=true; response.Kind=FrameKind.Hello; response.Hello=new Hello {MaxFrameBytesSupported=MaxFrame}; response.Hello.SupportedVersions.Add(1);
                        }
                        else
                        {
                            if(!negotiated) throw new ApiError(400,"HELLO_REQUIRED");
                            switch(request.Kind)
                            {
                                case FrameKind.SendEncrypted when request.Encrypted is not null:
                                    var e=request.Encrypted;
                                    if(e.SenderDeviceId.Length>0 && Id(e.SenderDeviceId)!=actor.DeviceId) throw new ApiError(403,"SENDER_MISMATCH");
                                    if(e.CiphertextSha256.Length>0 && !CryptographicOperations.FixedTimeEquals(e.CiphertextSha256.Span,SHA256.HashData(e.OpaqueCiphertext.Span))) throw new ApiError(400,"DIGEST_MISMATCH");
                                    var saved=await delivery.Send(actor,new SendRequest(Id(e.ConversationId),Id(e.ClientMessageId),checked((long)e.MlsEpoch),(int)e.EnvelopeKind,e.OpaqueCiphertext.ToByteArray()),timeout.Token);
                                    response.Kind=FrameKind.DurableAck;
                                    response.DurableAck=new DurableAck {ConversationId=e.ConversationId,ClientMessageId=e.ClientMessageId,ServerMessageId=Bytes(saved.ServerMessageId),ServerSequence=(ulong)saved.ServerSequence,AlreadyCommitted=saved.AlreadyCommitted};
                                    break;
                                case FrameKind.SyncRequest when request.SyncRequest is not null:
                                    var q=request.SyncRequest;
                                    var page=await delivery.Sync(actor,Id(q.ConversationId),q.OpaqueCursor.ToStringUtf8(),q.Limit==0?100:checked((int)q.Limit),timeout.Token);
                                    response.Kind=FrameKind.SyncResponse;
                                    response.SyncResponse=new SyncResponse {ConversationId=q.ConversationId,NextCursor=ByteString.CopyFromUtf8(page.NextCursor),HasMore=page.HasMore};
                                    foreach(var m in page.Messages) response.SyncResponse.Messages.Add(new EncryptedEnvelope {ConversationId=Bytes(m.ConversationId),ClientMessageId=Bytes(m.ClientMessageId),SenderDeviceId=Bytes(m.SenderDeviceId),MlsEpoch=(ulong)m.MlsEpoch,EnvelopeKind=(EnvelopeKind)m.EnvelopeKind,OpaqueCiphertext=ByteString.CopyFrom(m.Ciphertext),CiphertextSha256=ByteString.CopyFrom(m.CiphertextSha256),ServerSequence=(ulong)m.ServerSequence,ServerMessageId=Bytes(m.ServerMessageId)});
                                    break;
                                case FrameKind.ProcessedAck when request.ProcessedAck is not null:
                                    var a=request.ProcessedAck;
                                    await delivery.Ack(actor,new ProcessedAckRequest(Id(a.ConversationId),checked((long)a.HighestContiguousPersistedSequence)));
                                    response.Kind=FrameKind.ProcessedAck; response.ProcessedAck=a;
                                    break;
                                case FrameKind.Ping: response.Kind=FrameKind.Pong; break;
                                default: throw new ApiError(400,"UNSUPPORTED_FRAME");
                            }
                        }
                    }
                    catch(ApiError e) {response=new Frame{ProtocolVersion=1,RequestId=request.RequestId,Kind=FrameKind.ServerError,ServerError=new Error {Code=(uint)e.Status,StableCode=e.Code}};}
                    catch(NpgsqlException) {response=new Frame{ProtocolVersion=1,RequestId=request.RequestId,Kind=FrameKind.ServerError,ServerError=new Error {Code=503,StableCode="STORAGE_UNAVAILABLE",RetryAfterMs=1000}};}
                    using var output=new MemoryStream();
                    response.WriteDelimitedTo(output);
                    await ws.SendAsync(output.ToArray(),WebSocketMessageType.Binary,true,timeout.Token);
                    if(response.ServerError?.Code==401) {await ws.CloseOutputAsync(WebSocketCloseStatus.PolicyViolation,"authentication expired",CancellationToken.None);return;}
                }
            }
            catch(Exception e) when(e is OperationCanceledException or WebSocketException or InvalidProtocolBufferException or ApiError or OverflowException or ArgumentException)
            {
                ws.Abort(); // no content, frame or token in logs; client must resume through sync.
            }
        });
    }
    private static Guid Id(ByteString value) => value.Length==16?new Guid(value.Span,true):throw new ApiError(400,"INVALID_UUID");
    private static ByteString Bytes(Guid value) => ByteString.CopyFrom(value.ToByteArray(true));
}
