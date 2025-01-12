//
//  WMFImageControllerCancellationTests.swift
//  Wikipedia
//
//  Created by Brian Gerstle on 8/11/15.
//  Copyright (c) 2015 Wikimedia Foundation. All rights reserved.
//

import UIKit
import XCTest
@testable import Wikipedia
import PromiseKit
import Nocilla

/** 
 Protocol which intercepts all HTTP requests and prevents them from ever starting.
 
 Useful for reliably testing cancellation, since you're guaranteed to never get a successful or error response.
 
 - warning: Be sure to unregister this class after your test!
*/
class HTTPHangingProtocol : NSURLProtocol {
    override class func canInitWithRequest(request: NSURLRequest) -> Bool {
        return request.URL?.scheme.hasPrefix("http") ?? false
    }

    override class func canonicalRequestForRequest(request: NSURLRequest) -> NSURLRequest {
        return request
    }

    override func startLoading() {
        // never start requests
    }

    override func stopLoading() {
        // never started
    }
}

class WMFImageControllerTests: XCTestCase {
    private typealias ImageDownloadPromiseErrorCallback = (Promise<WMFImageDownload>) -> ((ErrorType) -> Void) -> Void

    var imageController: WMFImageController!

    override func setUp() {
        super.setUp()
        imageController = WMFImageController.temporaryController()
    }

    override func tearDown() {
        super.tearDown()
        // might have been set to nil in one of the tests. delcared as implicitly unwrapped for convenience
        imageController?.deleteAllImages()
        LSNocilla.sharedInstance().stop()
    }

    // MARK: - Simple fetching

    func testReceivingDataResponseResolves() {
        let testURL = NSURL(string: "https://upload.wikimedia.org/foo")!
        let stubbedData = UIImagePNGRepresentation(UIImage(named: "lead-default")!)

        LSNocilla.sharedInstance().start()
        stubRequest("GET", testURL.absoluteString).andReturnRawResponse(stubbedData)

        expectPromise(toResolve(),
            pipe: { imgDownload in
                XCTAssertEqual(UIImagePNGRepresentation(imgDownload.image), stubbedData)
            }) { () -> Promise<WMFImageDownload> in
                self.imageController.fetchImageWithURL(testURL)
            }
    }


    func testReceivingErrorResponseRejects() {
        let testURL = NSURL(string: "https://upload.wikimedia.org/foo")!
        let stubbedError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: nil)

        LSNocilla.sharedInstance().start()
        stubRequest("GET", testURL.absoluteString).andFailWithError(stubbedError)

        expectPromise(toReport() as ImageDownloadPromiseErrorCallback,
            pipe: { error in
                let error = error as NSError
                XCTAssertEqual(error.code, stubbedError.code)
                XCTAssertEqual(error.domain, stubbedError.domain)
                // ErrorType <-> NSError conversions lose userInfo? https://forums.developer.apple.com/thread/4809
                // let failingURL = error.userInfo[NSURLErrorFailingURLErrorKey] as! NSURL
                // XCTAssertEqual(failingURL, testURL)
            }) { () -> Promise<WMFImageDownload> in
                self.imageController.fetchImageWithURL(testURL)
            }
    }

    // MARK: - Cancellation

    func testCancelUnresolvedRequestCatchesWithCancellationError() {
        NSURLProtocol.registerClass(HTTPHangingProtocol)
        defer {
            NSURLProtocol.unregisterClass(HTTPHangingProtocol)
        }
        let testURL = NSURL(string:"https://foo")!
        expectPromise(toReport(ErrorPolicy.AllErrors) as ImageDownloadPromiseErrorCallback,
        pipe: { (err: ErrorType) -> Void in
            XCTAssert((err as! CancellableErrorType).cancelled, "Expected promise error to be cancelled but was \(err)")
        },
        timeout: 5) { () -> Promise<WMFImageDownload> in
            let promise: Promise<WMFImageDownload> =
                self.imageController.fetchImageWithURL(testURL, options: WMFImageController.backgroundImageFetchOptions)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(NSEC_PER_SEC * 2)), dispatch_get_global_queue(0, 0)) {
                self.imageController.cancelFetchForURL(testURL)
            }
            return promise
        }
    }

    func testDeallocCancelsUnresovledFetches() {
        NSURLProtocol.registerClass(HTTPHangingProtocol)
        defer {
            NSURLProtocol.unregisterClass(HTTPHangingProtocol)
        }
        let testURL = NSURL(string:"https://github.com/wikimedia/wikipedia-ios/blob/master/WikipediaUnitTests/Fixtures/golden-gate.jpg?raw=true")!
        expectPromise(toReport(ErrorPolicy.AllErrors) as ImageDownloadPromiseErrorCallback,
            pipe: { (err: ErrorType) -> Void in
                XCTAssert((err as! CancellableErrorType).cancelled, "Expected promise error to be cancelled but was \(err)")
            },
            timeout: 5) { () -> Promise<WMFImageDownload> in
                let promise: Promise<WMFImageDownload> =
                self.imageController.fetchImageWithURL(testURL, options: WMFImageController.backgroundImageFetchOptions)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(NSEC_PER_SEC * 2)), dispatch_get_global_queue(0, 0)) {
                    self.imageController = nil
                }
                return promise
        }
    }

    func testCancelCacheRequestCatchesWithCancellationError() throws {
        NSURLProtocol.registerClass(HTTPHangingProtocol)
        defer {
            NSURLProtocol.unregisterClass(HTTPHangingProtocol)
        }
        // copy some test fixture image to a temp location
        let testFixtureDataPath = NSURL(string: wmf_bundle().resourcePath!)!.URLByAppendingPathComponent("golden-gate.jpg")
        let tempPath = NSURL(string:WMFRandomTemporaryFileOfType("jpg"))!
        try! NSFileManager.defaultManager().copyItemAtURL(testFixtureDataPath, toURL: tempPath)
        defer {
            // remove temporarily copied test data
            try! NSFileManager.defaultManager().removeItemAtURL(tempPath)
        }
        let testURL = NSURL(string: "//foo/bar")!

        expectPromise(toReport(ErrorPolicy.AllErrors) as ImageDownloadPromiseErrorCallback,
        pipe: { (err: ErrorType) -> Void in
            XCTAssert((err as! CancellableErrorType).cancelled, "Expected promise error to be cancelled but was \(err)")
        },
        timeout: 2) { () -> Promise<WMFImageDownload> in
            self.imageController
                // import temp fixture data into image controller's disk cache
                .importImage(fromFile: tempPath.absoluteString, withURL: testURL)
                // then, attempt to retrieve it from the cache
                .then() {
                  let promise = self.imageController.cachedImageWithURL(testURL)
                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(NSEC_PER_SEC * 2)), dispatch_get_global_queue(0, 0)) {
                      // but, cancel before the data is retrieved
                      self.imageController.cancelFetchForURL(testURL)
                  }
                  return promise
                }
        }
    }

    // MARK: - Import

    func testImportImageMovesFileToCorrespondingPathInDiskCache() {
        let testFixtureDataPath =
            NSURL(fileURLWithPath: wmf_bundle().resourcePath!).URLByAppendingPathComponent("golden-gate.jpg")

        let tempImageCopyURL = NSURL(fileURLWithPath: WMFRandomTemporaryFileOfType("jpg"))

        try! NSFileManager.defaultManager().copyItemAtURL(testFixtureDataPath, toURL: tempImageCopyURL)

        let testURL = NSURL(string: "//foo/bar")!

        expectPromise(toResolve(), timeout: 2) {
            self.imageController.importImage(fromFile: tempImageCopyURL.path!, withURL: testURL)
        }

        XCTAssertFalse(self.imageController.hasDataInMemoryForImageWithURL(testURL),
                       "Importing image to disk should bypass the memory cache")

        XCTAssertTrue(self.imageController.hasDataOnDiskForImageWithURL(testURL))

        XCTAssertEqual(self.imageController.diskDataForImageWithURL(testURL),
                       NSFileManager.defaultManager().contentsAtPath(testFixtureDataPath.path!))
    }
}
