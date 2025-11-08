//
//  WASMFunctions.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-05.
//

import Foundation

// This function name *must* match the `swiftHostPrintCallback`
// forward-declaration in `wasm_host.c`.
// @_silgen_name exposes it to the C linker.

@_silgen_name("swiftHostPrintCallback")
func swiftHostPrintCallback(_ str: UnsafePointer<CChar>?) {
	guard let cString = str else { return }
	let message = String(cString: cString)
	
	// Print the message from WASM
	print("[WASM] \(message)")
}
