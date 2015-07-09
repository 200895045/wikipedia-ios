//
//  WMFImageController.swift
//  Wikipedia
//
//  Created by Brian Gerstle on 6/22/15.
//  Copyright (c) 2015 Wikimedia Foundation. All rights reserved.
//

import Foundation

///
/// @name Constants
///

public let WMFImageControllerErrorDomain = "WMFImageControllerErrorDomain"
public enum WMFImageControllerErrorCode: Int {
    case DataNotFound
    case FetchCancelled
    case InvalidOrEmptyURL

    var error: NSError {
        return NSError(domain: WMFImageControllerErrorDomain, code: self.rawValue, userInfo: nil)
    }
}

public func ==(err: NSError, cacheErrCode: WMFImageControllerErrorCode) -> Bool {
    return err.code == cacheErrCode.rawValue
}

// need to declare the "flipped" version of NSError == WMFImageCacheErrorCode
public func ==(cacheErrorCode: WMFImageControllerErrorCode, err: NSError) -> Bool {
    return err == cacheErrorCode
}

@objc
public class WMFImageController : NSObject {

    public override class func initialize() {
        if self === WMFImageController.self {
            NSError.registerCancelledErrorDomain(WMFImageControllerErrorDomain,
                                                 code: WMFImageControllerErrorCode.FetchCancelled.rawValue)
        }
    }

    /// MARK: - Initialization

    private static let defaultNamespace = "default"

    private static let _sharedInstance: WMFImageController = {
        let downloader = SDWebImageDownloader.sharedDownloader()
        let cache = WMFImageController.newPersistentCache(defaultNamespace)
        return WMFImageController(manager: SDWebImageManager(downloader: downloader, cache: cache),
                                  namespace: defaultNamespace)
    }()

    class func sharedInstance() -> WMFImageController {
        return _sharedInstance
    }

    //XC6: @testable
    public let imageManager: SDWebImageManager

    public class func newPersistentCache(namespace: String) -> SDImageCache {
        let appSupportDirectory =
            NSSearchPathForDirectoriesInDomains(.ApplicationSupportDirectory, .UserDomainMask, true).first as! String
        let cache = SDImageCache(namespace: namespace, inDirectory: appSupportDirectory)
        return cache
    }

    private let cancellingQueue: dispatch_queue_t

    private lazy var cancellables: NSMapTable = {
        NSMapTable.strongToWeakObjectsMapTable()
    }()

    public required init(manager: SDWebImageManager, namespace: String) {
        self.imageManager = manager;
        self.imageManager.cacheKeyFilter = { $0.wmf_schemelessURLString() }
        self.cancellingQueue = dispatch_queue_create("org.wikimedia.wikipedia.wmfimagecontroller.\(namespace)",
                                                     DISPATCH_QUEUE_SERIAL)
        super.init()
    }

    deinit {
        cancelAllFetches()
    }

    /// MARK: - Complex Fetching

    /**
     * Perform a cascading fetch which attempts to retrieve a "main" image from memory, or fall back to a
     * placeholder while fetching the image in the background.
     *
     * The "cascade" executes the following:
     *
     * - if mainURL is in cache, return immediately
     * - else, fetch placeholder from cache
     * - then, mainURL from network
     *
     * @return A promise which is resolved when the entire cascade is finished, or rejected when an error occurs.
     */
    public func cascadingFetchWithMainURL(mainURL: NSURL?,
                                          cachedPlaceholderURL: NSURL?,
                                          mainImageBlock: (ImageDownload) -> Void,
                                          cachedPlaceholderImageBlock: (ImageDownload) -> Void) -> Promise<Void> {
        weak var wself = self
        if hasImageWithURL(mainURL) {
            // if mainURL is cached, return it immediately w/o fetching placeholder
            return cachedImageWithURL(mainURL).then(mainImageBlock)
        }
        // return cached placeholder (if available)
        return cachedImageWithURL(cachedPlaceholderURL)
        // handle cached placeholder
        .then() { cachedPlaceholderImageBlock($0) }
        // ignore cache misses for placeholder
        .recover() { error in
            let empty: Void
            return Promise(empty)
        }
        // when placeholder handling is finished, fetch mainURL
        .then() { () -> Promise<ImageDownload> in
            if let sself = wself {
                return sself.fetchImageWithURL(mainURL)
            } else {
                return WMFImageController.cancelledPromise()
            }
        }
        // handle the main image
        .then() { mainImageBlock($0) }
    }

    /// MARK: - Simple Fetching

    /**
     * Retrieve the data and uncompressed image for `url`.
     *
     * @param url URL which corresponds to the image being retrieved. Ignores URL schemes.
     *
     * @return An `ImageDownload` with the image data and the origin it was loaded from.
     */
    public func fetchImageWithURL(url: NSURL) -> Promise<ImageDownload> {
        let promise = imageManager.promisedImageWithURL(url, options: SDWebImageOptions.allZeros)
        return maybeApplyDebugTransforms(promise)
    }

    public func fetchImageWithURL(url: NSURL?) -> Promise<ImageDownload> {
        return checkForValidURL(url, then: fetchImageWithURL)
    }

    /// @return Whether or not a fetch is outstanding for an image with `url`.
    public func isDownloadingImageWithURL(url: NSURL) -> Bool {
        return imageManager.imageDownloader.isDownloadingImageAtURL(url)
    }

    // MARK: - Caching

    /// @return Whether or not the image corresponding to `url` has been downloaded (ignores URL schemes).
    public func hasImageWithURL(url: NSURL?) -> Bool {
        return url == nil ? false : imageManager.cachedImageExistsForURL(url!)
    }

    public func deleteImageWithURL(url: NSURL) {
        self.imageManager.imageCache.removeImageForKey(cacheKeyForURL(url))
    }

    public func cachedImageWithURL(url: NSURL?) -> Promise<ImageDownload> {
        return checkForValidURL(url, then: cachedImageWIthURL)
    }

    public func cachedImageWIthURL(url: NSURL) -> Promise<ImageDownload> {
        let cancellablePromise = imageManager.imageCache.queryDiskCacheForKey(cacheKeyForURL(url))
        addCancellableForURL(cancellablePromise, url: url)
        return maybeApplyDebugTransforms(cancellablePromise.then() { image, origin in
            return ImageDownload(url: url, image: image, origin: origin)
        })
    }

    private func cacheKeyForURL(url: NSURL) -> String {
        return imageManager.cacheKeyForURL(url)
    }

    /**
     * Utility which returns a rejected promise for `nil` URLs, or passes valid URLs to function `then`.
     * @return A rejected promise with `InvalidOrEmptyURL` error if `url` is `nil`, otherwise the promise from `then`.
     */
    private func checkForValidURL(url: NSURL?, then: (NSURL) -> Promise<ImageDownload>) -> Promise<ImageDownload> {
        if url == nil { return Promise(WMFImageControllerErrorCode.InvalidOrEmptyURL.error) }
        else { return then(url!) }
    }

    // MARK: - Cancellation

    /// Cancel a pending fetch for an image at `url`.
    public func cancelFetchForURL(url: NSURL?) {
        if let url = url {
            weak var wself = self;
            dispatch_async(self.cancellingQueue) {
                let sself = wself
                if let cancellable = sself?.cancellables.objectForKey(url.absoluteString!) as? WrapperObject<Cancellable> {
                    sself?.cancellables.removeObjectForKey(url.absoluteString!)
                    cancellable.value.cancel()
                }
            }
        }
    }

    public func cancelAllFetches() {
        weak var wself = self;
        dispatch_async(self.cancellingQueue) {
            let sself = wself
            let currentCancellables: [WrapperObject<Cancellable>] =
                sself?.cancellables.objectEnumerator().allObjects as! [WrapperObject<Cancellable>]
            sself?.cancellables.removeAllObjects()
            dispatch_async(dispatch_get_global_queue(0, 0)) {
                for cancellable in currentCancellables {
                    cancellable.value.cancel()
                }
            }
        }
    }

    private func addCancellableForURL(cancellable: Cancellable, url: NSURL) {
        weak var wself = self;
        dispatch_async(self.cancellingQueue) {
            let sself = wself
            sself?.cancellables.setObject(WrapperObject(value: cancellable), forKey: url.absoluteString!)
        }
    }

    /// Utility for creating a `Promise` cancelled with a WMFImageController error
    public class func cancelledPromise<T>() -> Promise<T> {
        return Promise<T>(WMFImageControllerErrorCode.FetchCancelled.error)
    }

    /// Utility for creating an `AnyPromise` cancelled with a WMFImageController error
    public class func cancelledPromise() -> AnyPromise {
        return AnyPromise(bound: cancelledPromise() as Promise<Void>)
    }
}

/// MARK: - Objective-C Bridge

extension WMFImageController {
    /**
     * Objective-C-compatible variant of fetchImageWithURL(url:) returning an `AnyPromise`.
     *
     * @return `AnyPromise` which resolves to `UIImage`.
     */
    public func fetchImageWithURL(url: NSURL?) -> AnyPromise {
        return AnyPromise(bound: fetchImageWithURL(url).then(unpackImage()))
    }

    /**
     * Objective-C-compatible variant of cachedImageWithURL(url:) returning an `AnyPromise`.
     *
     * @return `AnyPromise` which resolves to `UIImage?`, where the image is present on a cache hit, and `nil` on a miss.
     */
    public func cachedImageWithURL(url: NSURL?) -> AnyPromise {
        return AnyPromise(bound: cachedImageWithURL(url).then(unpackImage()))
    }

    public func cascadingFetchWithMainURL(mainURL: NSURL?,
                                          cachedPlaceholderURL: NSURL?,
                                          mainImageBlock: (UIImage) -> Void,
                                          cachedPlaceholderImageBlock: (UIImage) -> Void) -> AnyPromise {
        let promise: Promise<Void> =
        cascadingFetchWithMainURL(mainURL,
                                  cachedPlaceholderURL: cachedPlaceholderURL,
                                  mainImageBlock: { mainImageBlock($0.image) },
                                  cachedPlaceholderImageBlock:  { cachedPlaceholderImageBlock($0.image) })
        return AnyPromise(bound: promise)
    }

    /// Curried function taking `Void`, then an `ImageDownload`, returning its `image`
    private func unpackImage()(download: ImageDownload) -> UIImage {
        return download.image
    }
}
