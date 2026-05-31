import Foundation
import XPCProtocol

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: WriteServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: WriteProgressObserver.self)
        let service = WriteService(connection: connection)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener(machServiceName: XPCConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
