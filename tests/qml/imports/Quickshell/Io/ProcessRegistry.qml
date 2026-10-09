pragma Singleton
import QtQml

// Every Process the code under test creates, so a test can find the one it
// wants and play the CLI's part.
QtObject {
  property var processes: []
  function add(process) { processes = processes.concat([process]) }
  function remove(process) { processes = processes.filter(function(p) { return p !== process }) }
  function reset() { processes = [] }
}
