use std::io::{self, BufRead, Read, Write};
fn main() {
    if std::env::args().nth(1).as_deref() == Some("--validate-keypackage") {
        let result = (|| -> anyhow::Result<String> {
            let mut input = String::new();
            io::stdin().take(65537).read_to_string(&mut input)?;
            anyhow::ensure!(input.len() <= 65536, "input too large");
            securemesh_crypto::validate_keypackage(&input)
        })();
        match result {
            Ok(value) => println!("{value}"),
            Err(_) => {
                eprintln!("PUBLIC_KEYPACKAGE_REJECTED");
                std::process::exit(1);
            }
        }
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("--serve") {
        if serve().is_err() {
            eprintln!("CRYPTO_OR_STORE_REJECTED");
            std::process::exit(1);
        }
        return;
    }
    let result = (|| -> anyhow::Result<String> {
        let path = std::env::args()
            .nth(1)
            .ok_or_else(|| anyhow::anyhow!("DB path required"))?;
        let mut input = String::new();
        io::stdin()
            .take(securemesh_crypto::MAX_LOCAL_COMMAND_BYTES as u64 + 1)
            .read_to_string(&mut input)?;
        securemesh_crypto::execute_json(&path, &input)
    })();
    match result {
        Ok(value) => println!("{value}"),
        Err(_) => {
            eprintln!("CRYPTO_OR_STORE_REJECTED");
            std::process::exit(1);
        }
    }
}

fn serve() -> anyhow::Result<()> {
    let path = std::env::args()
        .nth(2)
        .ok_or_else(|| anyhow::anyhow!("path required"))?;
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    let mut first = String::new();
    reader.by_ref().take(262145).read_line(&mut first)?;
    let first: serde_json::Value = serde_json::from_str(&first)?;
    let pass = first["passphrase"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("passphrase required"))?;
    let client = securemesh_crypto::api::NativeClient::open(path, pass.to_owned())
        .map_err(anyhow::Error::msg)?;
    println!("{{\"unlocked\":true}}");
    io::stdout().flush()?;
    loop {
        let mut line = String::new();
        let n = reader
            .by_ref()
            .take(securemesh_crypto::MAX_LOCAL_COMMAND_BYTES as u64 + 1)
            .read_line(&mut line)?;
        if n == 0 {
            break;
        }
        anyhow::ensure!(
            line.len() <= securemesh_crypto::MAX_LOCAL_COMMAND_BYTES,
            "input too large"
        );
        match client.execute(line) {
            Ok(value) => println!("{value}"),
            Err(_) => println!("{{\"error\":\"CRYPTO_OR_STORE_REJECTED\"}}"),
        }
        io::stdout().flush()?;
    }
    Ok(())
}
