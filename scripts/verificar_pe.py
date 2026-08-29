#!/usr/bin/env python3
"""Verifica que un archivo sea un ejecutable PE32+ (x86_64) válido, SIN ejecutarlo.

Es la sonda del workflow build-image-escritorio.yml tras el cross-compile con
cargo-xwin: comprueba que el .exe resultante tiene la forma que MSVC/lld-link
producen para Windows x86_64, leyendo solo la cabecera (nada de wine, nada de
correr el binario). Si algo no cuadra, imprime lo esperado y lo recibido para
que el fallo se entienda sin tener que abrir el binario a mano.

Uso: python3 verificar_pe.py <ruta-al-exe>
"""

from __future__ import annotations

import struct
import sys

# Constantes del formato PE (ver especificación de Microsoft "PE Format").
DOS_MAGIC = b"MZ"
PE_SIGNATURE = b"PE\x00\x00"
IMAGE_FILE_MACHINE_AMD64 = 0x8664
PE32_PLUS_MAGIC = 0x20B
# Subsystem: 2 = Windows GUI, 3 = Windows CUI (consola). Un binario de Tauri
# (o la sonda de `cargo new --bin`) cae en uno de los dos.
SUBSYSTEMS_VALIDOS = {2, 3}


class VerificacionPeError(Exception):
    """Cabecera PE inválida o distinta de lo esperado para x86_64 Windows."""


def _fallo(campo: str, esperado: str, recibido: str) -> None:
    raise VerificacionPeError(f"{campo}: esperado {esperado}, recibido {recibido}")


def verificar_pe(datos: bytes) -> None:
    """Lanza VerificacionPeError si `datos` no es un PE32+ (x86_64) válido."""
    if len(datos) < 0x40:
        _fallo(
            "tamaño del archivo",
            ">= 0x40 bytes (cabecera DOS mínima)",
            f"{len(datos)} bytes",
        )

    # ---- Cabecera DOS: firma "MZ" en el offset 0 ---------------------------
    firma_dos = datos[0:2]
    if firma_dos != DOS_MAGIC:
        _fallo("firma DOS (offset 0x00)", repr(DOS_MAGIC), repr(firma_dos))

    # ---- e_lfanew en 0x3C: offset a la cabecera PE -------------------------
    (e_lfanew,) = struct.unpack_from("<I", datos, 0x3C)
    fin_firma_pe = e_lfanew + 4
    if fin_firma_pe > len(datos):
        _fallo(
            "e_lfanew (offset 0x3C)",
            f"un valor que quepa en el archivo (< {len(datos) - 4})",
            str(e_lfanew),
        )

    # ---- Firma PE\0\0 -------------------------------------------------------
    firma_pe = datos[e_lfanew:fin_firma_pe]
    if firma_pe != PE_SIGNATURE:
        _fallo(
            f"firma PE (offset {hex(e_lfanew)})",
            repr(PE_SIGNATURE),
            repr(firma_pe),
        )

    # ---- COFF File Header: Machine (2 bytes justo tras la firma PE) -------
    offset_machine = fin_firma_pe
    (machine,) = struct.unpack_from("<H", datos, offset_machine)
    if machine != IMAGE_FILE_MACHINE_AMD64:
        _fallo(
            f"Machine (offset {hex(offset_machine)})",
            f"{hex(IMAGE_FILE_MACHINE_AMD64)} (IMAGE_FILE_MACHINE_AMD64)",
            hex(machine),
        )

    # ---- COFF File Header: NumberOfSections y SizeOfOptionalHeader --------
    # Layout del COFF File Header (20 bytes): Machine(2) NumberOfSections(2)
    # TimeDateStamp(4) PointerToSymbolTable(4) NumberOfSymbols(4)
    # SizeOfOptionalHeader(2) Characteristics(2).
    offset_size_optional_header = offset_machine + 16
    (size_optional_header,) = struct.unpack_from(
        "<H", datos, offset_size_optional_header
    )
    offset_optional_header = offset_machine + 20  # tras el COFF File Header (20 bytes)
    if size_optional_header < 2 or (offset_optional_header + 2 > len(datos)):
        _fallo(
            "SizeOfOptionalHeader",
            "un Optional Header presente y completo en el archivo",
            str(size_optional_header),
        )

    # ---- Optional Header: Magic (PE32+ para x86_64) ------------------------
    (magic,) = struct.unpack_from("<H", datos, offset_optional_header)
    if magic != PE32_PLUS_MAGIC:
        _fallo(
            f"Magic del Optional Header (offset {hex(offset_optional_header)})",
            f"{hex(PE32_PLUS_MAGIC)} (PE32+, imagen de 64 bits)",
            hex(magic),
        )

    # ---- Optional Header: Subsystem ----------------------------------------
    # En PE32+ el campo Subsystem vive en el offset 68 del Optional Header
    # (Magic(2) MajorLinkerVersion(1) MinorLinkerVersion(1) SizeOfCode(4)
    # SizeOfInitializedData(4) SizeOfUninitializedData(4) AddressOfEntryPoint(4)
    # BaseOfCode(4) ImageBase(8) SectionAlignment(4) FileAlignment(4)
    # MajorOperatingSystemVersion(2) MinorOperatingSystemVersion(2)
    # MajorImageVersion(2) MinorImageVersion(2) MajorSubsystemVersion(2)
    # MinorSubsystemVersion(2) Win32VersionValue(4) SizeOfImage(4)
    # SizeOfHeaders(4) CheckSum(4) Subsystem(2) = offset 68).
    offset_subsystem = offset_optional_header + 68
    if offset_subsystem + 2 > len(datos):
        _fallo(
            "Subsystem",
            "un Optional Header completo (68+2 bytes) en el archivo",
            f"solo hay {len(datos) - offset_optional_header} bytes de Optional Header",
        )
    (subsystem,) = struct.unpack_from("<H", datos, offset_subsystem)
    if subsystem not in SUBSYSTEMS_VALIDOS:
        _fallo(
            f"Subsystem (offset {hex(offset_subsystem)})",
            f"uno de {sorted(SUBSYSTEMS_VALIDOS)} (2=GUI, 3=CUI de Windows)",
            str(subsystem),
        )


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"Uso: {argv[0]} <ruta-al-exe>", file=sys.stderr)
        return 2

    ruta = argv[1]
    try:
        with open(ruta, "rb") as f:
            datos = f.read()
    except OSError as exc:
        print(f"No se pudo leer '{ruta}': {exc}", file=sys.stderr)
        return 2

    try:
        verificar_pe(datos)
    except VerificacionPeError as exc:
        print(f"Cabecera PE inválida en '{ruta}': {exc}", file=sys.stderr)
        return 1

    print(f"OK: '{ruta}' es un PE32+ (x86_64) válido.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
