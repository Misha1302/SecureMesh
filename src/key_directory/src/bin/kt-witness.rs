use anyhow::{bail, ensure, Context, Result};
use ed25519_dalek::SigningKey;
use securemesh_key_directory::{
    store::Store,
    witness::{Policy, Vote, Witness},
    Checkpoint, MAX_PROOF_BYTES,
};
use std::{
    env,
    fs::File,
    io::{self, IsTerminal, Read},
    path::Path,
};
use zeroize::Zeroizing;

fn bounded(reader: impl Read, limit: usize) -> Result<Zeroizing<Vec<u8>>> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(limit + 1));
    reader.take(limit as u64 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= limit, "input exceeds size limit");
    Ok(bytes)
}

fn secret(limit: usize) -> Result<Zeroizing<Vec<u8>>> {
    ensure!(!io::stdin().is_terminal(), "redirect credential to stdin");
    bounded(io::stdin().lock(), limit)
}

fn fields<const N: usize>(path: &str) -> Result<[String; N]> {
    let data = bounded(File::open(path)?, 1024)?;
    std::str::from_utf8(&data)?
        .split_ascii_whitespace()
        .map(str::to_owned)
        .collect::<Vec<_>>()
        .try_into()
        .ok()
        .context("unexpected public file field count")
}

fn bytes<const N: usize>(value: &str) -> Result<[u8; N]> {
    let mut out = [0; N];
    hex::decode_to_slice(value, &mut out).context("invalid public hex field")?;
    Ok(out)
}

fn config(path: &str) -> Result<(Policy, [u8; 32])> {
    let [directory, vrf, a, b, c, d] = fields(path)?;
    let vrf = bytes(&vrf)?;
    Ok((
        Policy::new(
            bytes(&directory)?,
            vrf,
            [bytes(&a)?, bytes(&b)?, bytes(&c)?, bytes(&d)?],
        )?,
        vrf,
    ))
}

fn checkpoint(path: &str) -> Result<Checkpoint> {
    let [epoch, root] = fields(path)?;
    Ok(Checkpoint {
        epoch: epoch.parse()?,
        root: bytes(&root)?,
    })
}

fn votes(files: &[String]) -> Result<Vec<Vote>> {
    ensure!(
        (3..=4).contains(&files.len()),
        "expected three or four vote files"
    );
    files
        .iter()
        .map(|file| {
            let [slot, signature] = fields(file)?;
            Ok(Vote {
                slot: slot.parse()?,
                signature: bytes(&signature)?,
            })
        })
        .collect()
}

fn open_store(profile: &str, owner: &str, vrf: [u8; 32]) -> Result<Store> {
    let data = secret(4096)?;
    ensure!(
        data.len() >= 16 && !data.contains(&0),
        "invalid profile credential"
    );
    Store::open(
        Path::new(profile),
        std::str::from_utf8(&data).context("invalid profile credential encoding")?,
        owner,
        vrf,
    )
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    match args.as_slice() {
        [op, cfg, ledger, slot, pin] if op == "provision" => {
            Witness::provision(Path::new(ledger),config(cfg)?.0,slot.parse()?,checkpoint(pin)?)?;
        }
        [op, cfg, ledger, slot, old, next, proof] if op == "vote" => {
            let mut w = Witness::open(Path::new(ledger),config(cfg)?.0,slot.parse()?)?;
            let seed = secret(32)?;
            let key = SigningKey::from_bytes(seed.as_slice().try_into().context("expected raw 32-byte signing seed")?);
            let vote = w.cosign(&key,checkpoint(old)?,checkpoint(next)?,&bounded(File::open(proof)?,MAX_PROOF_BYTES)?).await?;
            println!("{} {}", vote.slot, hex::encode(vote.signature));
        }
        [op, cfg, profile, owner, pin] if op == "enroll" => {
            let (policy, vrf) = config(cfg)?;
            open_store(profile,owner,vrf)?.enroll_witnesses(checkpoint(pin)?, &policy)?;
        }
        [op, cfg, profile, owner, old, next, proof, files @ ..] if op == "advance" => {
            let (policy, vrf) = config(cfg)?;
            let votes = votes(files)?;
            let outcome = open_store(profile,owner,vrf)?.advance_witnessed(checkpoint(old)?,checkpoint(next)?,&bounded(File::open(proof)?,MAX_PROOF_BYTES)?,&policy,&votes).await?;
            println!("{outcome:?}");
        }
        _ => bail!("usage: kt-witness provision CONFIG LEDGER SLOT PIN | vote CONFIG LEDGER SLOT PREVIOUS NEXT PROOF | enroll CONFIG PROFILE OWNER PIN | advance CONFIG PROFILE OWNER PREVIOUS NEXT PROOF VOTE1 VOTE2 VOTE3 [VOTE4]"),
    }
    Ok(())
}
