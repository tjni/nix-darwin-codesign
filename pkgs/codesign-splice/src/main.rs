// SPDX-License-Identifier: MPL-2.0

use anyhow::{Context as _, Result};
use clap::{Parser, Subcommand};
use codesign_splice::{embed_detached_into_macho, extract_signature_from_macho, parse_detached};
use std::path::PathBuf;
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(version, about = "Splice precomputed Apple code signatures into Mach-O binaries")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

// Subcommand names mirror rcodesign's conventions
// (`print-signature-info`, `compute-code-hashes`, ...) so this tool's
// CLI reads as a companion to rcodesign. If the `embed-signature`
// operation ever lands upstream in rcodesign, migrating is a
// binary-name change, not a CLI redesign.
#[derive(Subcommand)]
enum Command {
    /// Embed a precomputed code signature into an unsigned Mach-O
    /// binary. Reads the signature from a file (produced by
    /// `codesign --detached` or `extract-signature`), splices it
    /// into `LC_CODE_SIGNATURE`, resizes `__LINKEDIT`, and writes
    /// the resulting signed Mach-O.
    EmbedSignature {
        /// Unsigned (or previously-signed) input Mach-O.
        #[arg(long)]
        input: PathBuf,

        /// Signature file: a bare `CSMAGIC_EMBEDDED_SIGNATURE` blob
        /// or an Apple `CSMAGIC_DETACHED_SIGNATURE` container.
        #[arg(long)]
        signature: PathBuf,

        /// Output path for the signed Mach-O.
        #[arg(long)]
        output: PathBuf,
    },

    /// Extract the embedded signature from a signed Mach-O.
    ///
    /// Writes the raw bytes of `LC_CODE_SIGNATURE` to the output
    /// path. These bytes are a bare `CSMAGIC_EMBEDDED_SIGNATURE`
    /// SuperBlob and can be re-applied later with `embed-signature`.
    ExtractSignature {
        /// Signed Mach-O binary to extract from.
        #[arg(long)]
        input: PathBuf,

        /// Output path for the extracted signature bytes.
        #[arg(long)]
        output: PathBuf,
    },

    /// Print structural info about a detached signature or bare
    /// embedded signature file. Mirrors rcodesign's command of the
    /// same name, with coverage limited to detached-sig containers
    /// and raw embedded-signature blobs.
    PrintSignatureInfo {
        /// Signature file to inspect.
        signature: PathBuf,
    },
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();

    let cli = Cli::parse();

    match cli.command {
        Command::EmbedSignature { input, signature, output } => {
            cmd_embed_signature(&input, &signature, &output)
        }
        Command::ExtractSignature { input, output } => cmd_extract_signature(&input, &output),
        Command::PrintSignatureInfo { signature } => cmd_print_signature_info(&signature),
    }
}

fn cmd_extract_signature(input: &std::path::Path, output: &std::path::Path) -> Result<()> {
    let macho_bytes = std::fs::read(input).with_context(|| format!("reading input {input:?}"))?;
    let sig = extract_signature_from_macho(&macho_bytes)?;
    std::fs::write(output, &sig).with_context(|| format!("writing output {output:?}"))?;
    println!("extracted {} bytes of signature to {output:?}", sig.len());
    Ok(())
}

fn cmd_embed_signature(
    input: &std::path::Path,
    signature: &std::path::Path,
    output: &std::path::Path,
) -> Result<()> {
    let macho_bytes = std::fs::read(input).with_context(|| format!("reading input {input:?}"))?;
    let sig_bytes =
        std::fs::read(signature).with_context(|| format!("reading signature {signature:?}"))?;

    let signed = embed_detached_into_macho(&macho_bytes, &sig_bytes)?;

    if let Some(parent) = output.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).ok();
        }
    }
    std::fs::write(output, &signed).with_context(|| format!("writing output {output:?}"))?;

    // Preserve executable bit from input.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let perms = std::fs::metadata(input)?.permissions();
        std::fs::set_permissions(output, std::fs::Permissions::from_mode(perms.mode()))?;
    }

    println!(
        "wrote {} bytes to {output:?} ({} bytes of signature)",
        signed.len(),
        sig_bytes.len()
    );
    Ok(())
}

fn cmd_print_signature_info(signature: &std::path::Path) -> Result<()> {
    let bytes = std::fs::read(signature).with_context(|| format!("reading {signature:?}"))?;
    let entries = parse_detached(&bytes)?;

    println!("file size: {} bytes", bytes.len());
    println!("entries:   {}", entries.len());
    for (i, e) in entries.iter().enumerate() {
        let label = match e.cpu_type {
            0 => "bundle resources",
            0x0100_000c => "CPU_TYPE_ARM64",
            0x0100_0007 => "CPU_TYPE_X86_64",
            0x0000_0007 => "CPU_TYPE_X86",
            other => {
                println!("  [{i}] cpu_type=0x{other:08x} len={} bytes", e.blob.len());
                continue;
            }
        };
        println!("  [{i}] {label} len={} bytes", e.blob.len());
    }

    Ok(())
}
