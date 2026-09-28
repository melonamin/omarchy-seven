.pragma library

// A library context survives service destruction. Keep writers alive until
// release() observes that their final queued write has finished.
var writers = []

function createWriter(url, helperPath, filePath) {
  var component = Qt.createComponent(url)
  var writer = component.createObject(null, { helperPath: helperPath, filePath: filePath })
  writers.push(writer)
  writer.retired.connect(function() { writers = writers.filter(function(value) { return value !== writer }) })
  return writer
}
