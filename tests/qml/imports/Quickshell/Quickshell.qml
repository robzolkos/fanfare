pragma Singleton
import QtQml

// Test stand-in for Quickshell's environment lookup.
QtObject {
  property var environment: ({ HOME: "/home/test", XDG_STATE_HOME: "/state" })
  function env(name) { return environment[name] || "" }
  function execDetached(command) {}
}
