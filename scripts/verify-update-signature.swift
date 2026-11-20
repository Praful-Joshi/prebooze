// Check an update's EdDSA signature against a public key, the way Sparkle does.
//   swift scripts/verify-update-signature.swift <file> <base64 signature> <base64 public key>
// Exits 0 if the signature is valid, 1 if not, 2 on bad input.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: verify-update-signature.swift <file> <signature> <public key>\n".utf8))
    exit(2)
}
guard let signature = Data(base64Encoded: arguments[2]),
      let keyData = Data(base64Encoded: arguments[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let file = FileManager.default.contents(atPath: arguments[1]) else {
    FileHandle.standardError.write(Data("verify-update-signature: unreadable file, signature or key\n".utf8))
    exit(2)
}
exit(key.isValidSignature(signature, for: file) ? 0 : 1)
