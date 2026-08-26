#!/usr/bin/env swift
//
// The Ed25519 key that signs MailSpace releases — created, used and checked
// here, and never anywhere near the login keychain.
//
//   swift scripts/update-tool.swift genkey
//   swift scripts/update-tool.swift pubkey <key-file>
//   swift scripts/update-tool.swift sign   <key-file> <file>      # prints base64
//   swift scripts/update-tool.swift verify <public-b64> <sig-b64> <file>
//
// The key file is base64 of the 32-byte Ed25519 seed and nothing else. It lives
// outside this repository (see scripts/make-update-key.sh) because it is the
// only thing that lets a download be recognised as a genuine MailSpace release:
// the app carries the public half and refuses anything it cannot verify.
//
// Deliberately CryptoKit and not the Keychain. Storing it in the keychain would
// mean a keychain-unlock prompt every time a release is cut, and this file has
// to be exportable to a password manager anyway — losing it means no installed
// copy will ever accept an update again.

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("update-tool: \(message)\n".utf8))
    exit(1)
}

func usage() -> Never {
    fail("usage: genkey | pubkey <key> | sign <key> <file> | verify <public-b64> <sig-b64> <file>")
}

func privateKey(at path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("cannot read the key file at \(path)")
    }
    guard
        let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
        seed.count == 32,
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    else {
        fail("\(path) is not base64 of a 32-byte Ed25519 seed")
    }
    return key
}

func contents(of path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

switch command {
case "genkey":
    let key = Curve25519.Signing.PrivateKey()
    // Private on stdout, public on stderr, so a caller can capture one without
    // ever having to filter the other out of the same stream.
    print(key.rawRepresentation.base64EncodedString())
    FileHandle.standardError.write(Data("\(key.publicKey.rawRepresentation.base64EncodedString())\n".utf8))

case "pubkey":
    guard arguments.count == 2 else { usage() }
    print(privateKey(at: arguments[1]).publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard arguments.count == 3 else { usage() }
    let key = privateKey(at: arguments[1])
    guard let signature = try? key.signature(for: contents(of: arguments[2])) else {
        fail("signing failed")
    }
    print(signature.base64EncodedString())

case "verify":
    guard arguments.count == 4 else { usage() }
    guard
        let rawKey = Data(base64Encoded: arguments[1]), rawKey.count == 32,
        let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    else {
        fail("the public key is not base64 of 32 bytes")
    }
    guard let signature = Data(base64Encoded: arguments[2]), signature.count == 64 else {
        fail("the signature is not base64 of 64 bytes")
    }
    guard key.isValidSignature(signature, for: contents(of: arguments[3])) else {
        fail("SIGNATURE DOES NOT VERIFY for \(arguments[3])")
    }
    print("ok")

default:
    usage()
}
