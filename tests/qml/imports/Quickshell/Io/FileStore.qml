pragma Singleton
import QtQml

// The files FileView reads and writes, by path, held in memory.
QtObject {
  property var files: ({})
  function read(path) { return files[path] }
  function write(path, text) { var next = {}; for (var k in files) next[k] = files[k]; next[path] = text; files = next }
  function reset() { files = {} }
}
