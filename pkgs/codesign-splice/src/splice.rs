// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Portions of this file are derived from apple-platform-rs
// (https://github.com/indygreg/apple-platform-rs), specifically
// `create_macho_with_signature` in `apple-codesign/src/macho_signing.rs`,
// by Gregory Szorc and contributors, also under MPL-2.0.
//
// The function is reimplemented here (rather than called directly)
// because apple-codesign keeps it private (`fn`, not `pub fn`). The
// implementation only uses public APIs — `MachOBinary`'s public
// methods, `goblin::mach` public items, `scroll` — so this is a
// lawful public-API reimplementation, not a bypass.
//
// Synced from apple-platform-rs commit b44a7f6... (2023), which is
// the most recent revision of this function. Re-sync by diffing
// `apple-codesign/src/macho_signing.rs::create_macho_with_signature`
// against this file; the logic should be point-for-point equivalent.
//
// TODO: once https://github.com/indygreg/apple-platform-rs adds a
// public `MachOSigner::embed_raw_superblob(&[u8])` (or a free
// function equivalent), delete this file and call the upstream
// version instead.
//
// Modifications from upstream: lifted into a standalone module,
// public entry point `embed_signature_in_macho` takes a
// `MachOBinary` + signature bytes and returns the new Mach-O file
// bytes.

use {
    apple_codesign::{AppleCodesignError, MachOBinary},
    goblin::mach::{
        constants::{SEG_LINKEDIT, SEG_PAGEZERO},
        load_command::{
            CommandVariant, LinkeditDataCommand, SegmentCommand32, SegmentCommand64,
            LC_CODE_SIGNATURE, SIZEOF_LINKEDIT_DATA_COMMAND,
        },
        parse_magic_and_ctx,
    },
    scroll::{ctx::SizeWith, IOwrite},
    std::{cmp::Ordering, io::Write},
    tracing::debug,
};

/// Embed precomputed signature bytes into a Mach-O binary's `__LINKEDIT`.
///
/// This performs the mechanical steps that the upstream signer does after it
/// has computed the SuperBlob: resize `__LINKEDIT`, update (or add)
/// `LC_CODE_SIGNATURE`, append the signature bytes with 16-byte alignment
/// padding, rewrite segment vmsize/filesize, and emit the new Mach-O bytes.
///
/// Caller is responsible for ensuring `signature_data` is a valid
/// `CSMAGIC_EMBEDDED_SIGNATURE` SuperBlob whose CodeDirectory matches this
/// Mach-O's code pages. We do not verify that invariant here.
pub fn embed_signature_in_macho(
    macho: &MachOBinary,
    signature_data: &[u8],
) -> Result<Vec<u8>, AppleCodesignError> {
    macho.check_signing_capability()?;

    let linkedit_data_before_signature = macho
        .linkedit_data_before_signature()
        .ok_or(AppleCodesignError::MissingLinkedit)?;

    let signature_file_offset = macho.code_limit_binary_offset()?;
    let remainder = (signature_file_offset % 16) as usize;
    let signature_padding_length = if remainder == 0 { 0 } else { 16 - remainder };

    let signature_file_offset = signature_file_offset + signature_padding_length as u64;

    let new_linkedit_segment_size =
        linkedit_data_before_signature.len() + signature_padding_length + signature_data.len();

    // codesign rounds up the segment's vmsize to the nearest 16kb boundary.
    let remainder = new_linkedit_segment_size % 16384;
    let new_linkedit_segment_vmsize = if remainder == 0 {
        new_linkedit_segment_size
    } else {
        new_linkedit_segment_size + 16384 - remainder
    };

    assert!(new_linkedit_segment_vmsize >= new_linkedit_segment_size);
    assert_eq!(new_linkedit_segment_vmsize % 16384, 0);

    let mut cursor = std::io::Cursor::new(Vec::<u8>::new());

    let ctx = parse_magic_and_ctx(macho.data, 0)?
        .1
        .expect("context should have been parsed before");

    let mut header = macho.macho.header;
    if macho.code_signature_load_command().is_none() {
        header.ncmds += 1;
        header.sizeofcmds += SIZEOF_LINKEDIT_DATA_COMMAND as u32;
    }

    cursor.iowrite_with(header, ctx)?;

    let mut seen_signature_load_command = false;

    for load_command in &macho.macho.load_commands {
        let original_command_data =
            &macho.data[load_command.offset..load_command.offset + load_command.command.cmdsize()];

        let written_len = match &load_command.command {
            CommandVariant::CodeSignature(command) => {
                seen_signature_load_command = true;

                let mut command = *command;
                command.dataoff = signature_file_offset as _;
                command.datasize = signature_data.len() as _;

                cursor.iowrite_with(command, ctx.le)?;

                LinkeditDataCommand::size_with(&ctx.le)
            }
            CommandVariant::Segment32(segment) => {
                let segment = match segment.name() {
                    Ok(SEG_LINKEDIT) => {
                        let mut segment = *segment;
                        segment.filesize = new_linkedit_segment_size as _;
                        segment.vmsize = new_linkedit_segment_vmsize as _;

                        segment
                    }
                    _ => *segment,
                };

                cursor.iowrite_with(segment, ctx.le)?;

                SegmentCommand32::size_with(&ctx.le)
            }
            CommandVariant::Segment64(segment) => {
                let segment = match segment.name() {
                    Ok(SEG_LINKEDIT) => {
                        let mut segment = *segment;
                        segment.filesize = new_linkedit_segment_size as _;
                        segment.vmsize = new_linkedit_segment_vmsize as _;

                        segment
                    }
                    _ => *segment,
                };

                cursor.iowrite_with(segment, ctx.le)?;

                SegmentCommand64::size_with(&ctx.le)
            }
            _ => {
                cursor.write_all(original_command_data)?;
                original_command_data.len()
            }
        };

        cursor.write_all(&original_command_data[written_len..])?;
    }

    if !seen_signature_load_command {
        let command = LinkeditDataCommand {
            cmd: LC_CODE_SIGNATURE,
            cmdsize: SIZEOF_LINKEDIT_DATA_COMMAND as _,
            dataoff: signature_file_offset as _,
            datasize: signature_data.len() as _,
        };

        cursor.iowrite_with(command, ctx.le)?;
    }

    let mut wrote_non_empty_segment = false;

    for segment in macho.segments_by_file_offset() {
        if matches!(segment.name(), Ok(SEG_PAGEZERO)) {
            continue;
        }

        match cursor.position().cmp(&segment.fileoff) {
            Ordering::Less => {
                let padding = &macho.data[cursor.position() as usize..segment.fileoff as usize];
                debug!(
                    bytes = padding.len(),
                    segment = segment.name().unwrap_or("<unknown>"),
                    "copying inter-segment padding"
                );
                cursor.write_all(padding)?;
            }
            Ordering::Greater if segment.fileoff == 0 => {}
            Ordering::Greater if !wrote_non_empty_segment => {}
            Ordering::Greater => {
                return Err(AppleCodesignError::MachOWrite(format!(
                    "Mach-O segment corruption: cursor at 0x{:x} but segment begins at 0x{:x}",
                    cursor.position(),
                    segment.fileoff
                )));
            }
            Ordering::Equal => {}
        }

        match segment.name() {
            Ok(SEG_LINKEDIT) => {
                cursor.write_all(
                    macho
                        .linkedit_data_before_signature()
                        .expect("__LINKEDIT segment data should resolve"),
                )?;

                let padding = vec![0u8; signature_padding_length];
                cursor.write_all(&padding)?;

                assert_eq!(cursor.position(), signature_file_offset);
                assert_eq!(cursor.position() % 16, 0);
                cursor.write_all(signature_data)?;
            }
            _ => {
                if segment.fileoff < cursor.position() {
                    if segment.data.is_empty() {
                        continue;
                    }
                    let remaining =
                        &segment.data[cursor.position() as usize..segment.filesize as usize];
                    cursor.write_all(remaining)?;
                } else {
                    cursor.write_all(segment.data)?;
                }
            }
        }

        wrote_non_empty_segment = true;
    }

    Ok(cursor.into_inner())
}
