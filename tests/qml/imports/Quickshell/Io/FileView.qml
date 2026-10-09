import QtQml

// Test stand-in backed by FileStore. reload() fires loaded or loadFailed.
QtObject {
  id: root
  property string path: ""
  property bool watchChanges: false
  property bool atomicWrites: false
  property bool printErrors: true
  signal loaded()
  signal loadFailed()
  function text() { return FileStore.read(path) || "" }
  function setText(value) { FileStore.write(path, value) }
  function reload() {
    if (FileStore.read(path) === undefined) loadFailed()
    else loaded()
  }
}
