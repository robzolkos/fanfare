import QtQml

// Test stand-in: starting it only records the command; the test finishes it
// with complete(exitCode, stdout, stderr).
QtObject {
  id: root
  property bool running: false
  property var command: []
  property var environment: ({})
  property var stdout: null
  property var stderr: null
  signal exited(int exitCode, int exitStatus)

  Component.onCompleted: ProcessRegistry.add(root)
  Component.onDestruction: ProcessRegistry.remove(root)

  function complete(exitCode, stdoutText, stderrText) {
    if (stdout) { stdout.text = stdoutText || ""; stdout.streamFinished() }
    if (stderr) { stderr.text = stderrText || ""; stderr.streamFinished() }
    running = false
    exited(exitCode, 0)
  }
}
