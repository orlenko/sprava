import BinderFormat
@testable import Capture
import Foundation
import Testing

func ids(_ page: NowPage, _ bucket: Bucket) -> [String] { page.items[bucket, default: []].map(\.idText) }
