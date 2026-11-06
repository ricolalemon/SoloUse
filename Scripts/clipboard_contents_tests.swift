import Foundation

@main struct ClipboardContentsTests {
  static func main() {
    let source = ClipboardContents(items: [
      ["public.utf8-plain-text": Data("中文🙂 AbC".utf8), "public.html": Data("<b>中文🙂 AbC</b>".utf8),
        "org.chromium.source-url": Data([0,1,2,255]), ClipboardContents.remoteOriginType: Data()],
      ["public.png": Data([137,80,78,71]), "org.nspasteboard.ConcealedType": Data()],
    ])
    let local = source.localCopy
    precondition(source.isRemoteCopy && !local.isRemoteCopy)
    precondition(local.items[0]["public.utf8-plain-text"] == source.items[0]["public.utf8-plain-text"])
    precondition(local.items[0]["public.html"] == source.items[0]["public.html"])
    precondition(local.items[0]["org.chromium.source-url"] == source.items[0]["org.chromium.source-url"])
    precondition(local.items[1] == source.items[1])
    precondition(local.bytes == source.bytes && local.formats == source.formats - 1)
    precondition(local.localCopy == local && source.items[0][ClipboardContents.remoteOriginType] != nil)
    print("PASS multi-item rich-text/image/private metadata preserved; confidential marker retained; source immutable")
    let markerOnly = ClipboardContents(items: [[ClipboardContents.remoteOriginType: Data()]])
    precondition(markerOnly.localCopy.items.isEmpty)
    let emptyText = ClipboardContents(items: [["public.utf8-plain-text": Data(), ClipboardContents.remoteOriginType: Data()]])
    precondition(emptyText.localCopy.items == [["public.utf8-plain-text": Data()]])
    print("PASS transport-only entries distinguished from genuine empty text")
  }
}
