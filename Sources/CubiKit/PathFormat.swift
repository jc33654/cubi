public enum PathFormat {
    /// "/Users/me/x" → "~/x" for the given home; "/Users/meow/x" stays as it is.
    public static func abbreviatingHome(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
