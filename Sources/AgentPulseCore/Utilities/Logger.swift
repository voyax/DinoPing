import os

extension os.Logger {
    public static let app = Logger(subsystem: "com.agentpulse.app", category: "general")
    public static let hookServer = Logger(subsystem: "com.agentpulse.app", category: "hookServer")
    public static let agentManager = Logger(subsystem: "com.agentpulse.app", category: "agentManager")
    public static let permission = Logger(subsystem: "com.agentpulse.app", category: "permission")
}
