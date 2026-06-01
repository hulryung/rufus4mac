import Foundation
import XPCProtocol

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only accept connections from code signed by the HUCONN team (Apple-anchored).
        // This root daemon raw-writes disks; an unpinned listener would let any local
        // process drive a destructive write to removable media.
        connection.setCodeSigningRequirement(
            "anchor apple generic and certificate leaf[subject.OU] = \"XGJ87M8ZZR\"")
        connection.exportedInterface = NSXPCInterface(with: WriteServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: WriteProgressObserver.self)
        let service = WriteService(connection: connection)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let cliArgs = CommandLine.arguments
if cliArgs.count >= 5, cliArgs[1] == "writepriv" {
    runWritePriv(imagePath: cliArgs[2], bsdName: cliArgs[3], sha256Base64: cliArgs[4])
}

let delegate = ServiceDelegate()
let listener = NSXPCListener(machServiceName: XPCConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
