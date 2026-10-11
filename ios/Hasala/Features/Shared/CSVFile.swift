import CoreTransferable
import Foundation
import HasalaModels
import UniformTypeIdentifiers

/// A CSV export as a file for the share sheet (spec 04 §16.2 T5, X6). The file is built
/// when the person shares it, from the rows on screen; nothing is written to disk first.
struct CSVFile: Transferable {
  let rows: [ExportRow]
  let name: String

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .commaSeparatedText) { file in
      Data(CSVExport.csv(file.rows).utf8)
    }
    .suggestedFileName { $0.name }
  }
}
