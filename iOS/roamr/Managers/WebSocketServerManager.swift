import SwiftUI
import Vapor

class WebSocketServerManager {
	var app: Application?
	var activeSockets: [WebSocket] = []

	func start() {
		var env = try! Environment.detect()
		try! LoggingSystem.bootstrap(from: &env)
		
		let app = Application(env)
		self.app = app
		
		// Simple WebSocket route
		app.webSocket("ws") { req, ws in
			self.activeSockets.append(ws)
			print("🔗 Client connected")
			
			ws.onText { ws, text in
				print("📩 Received: \(text)")
				ws.send("Echo: \(text)")
			}
			
			ws.onClose.whenComplete { _ in
				print("❌ Client disconnected")
			}
		}
		
		// Run on port 8080
		DispatchQueue.global().async {
			try? app.run()
		}
		
		//print("✅ WebSocket server started at ws://<iPhone-IP>:8080/ws")
	}
	
	func stop() {
		app?.shutdown()
	}
	
	func broadcast(_ message: String) {
		for ws in activeSockets {
			ws.send(message)
		}
	}
}
