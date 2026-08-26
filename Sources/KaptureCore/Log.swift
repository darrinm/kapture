import os

public enum Log {
    public static let capture = Logger(subsystem: "sh.kapture", category: "capture")
    public static let store = Logger(subsystem: "sh.kapture", category: "store")
    public static let shell = Logger(subsystem: "sh.kapture", category: "shell")
}
