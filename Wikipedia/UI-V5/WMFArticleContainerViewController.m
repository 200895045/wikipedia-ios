#import "WMFArticleContainerViewController.h"
#import "Wikipedia-Swift.h"

// Frameworks
#import <Masonry/Masonry.h>
#import <BlocksKit/BlocksKit+UIKit.h>

// Controller
#import "WMFArticleViewController.h"
#import "WebViewController.h"
#import "UIViewController+WMFStoryboardUtilities.h"
#import "WMFSaveButtonController.h"
#import "WMFPreviewController.h"
#import "WMFArticleContainerViewController_Transitioning.h"
#import "WMFArticleHeaderImageGalleryViewController.h"
#import "WMFRelatedTitleListDataSource.h"
#import "WMFArticleListCollectionViewController.h"
#import "UITabBarController+WMFExtensions.h"
#import "WMFShareFunnel.h"
#import "WMFShareOptionsController.h"
#import "WMFImageGalleryViewController.h"

// Model
#import "MWKDataStore.h"
#import "MWKArticle+WMFAnalyticsLogging.h"
#import "MWKCitation.h"
#import "MWKTitle.h"
#import "MWKSavedPageList.h"
#import "MWKUserDataStore.h"
#import "MWKArticle+WMFSharing.h"
#import "MWKArticlePreview.h"
#import "MWKHistoryList.h"

// Networking
#import "WMFArticleFetcher.h"

// View
#import "UIBarButtonItem+WMFButtonConvenience.h"
#import "UIScrollView+WMFContentOffsetUtils.h"
#import "UIWebView+WMFTrackingView.h"
#import "NSArray+WMFLayoutDirectionUtilities.h"
#import "UIViewController+WMFOpenExternalUrl.h"

NS_ASSUME_NONNULL_BEGIN

@interface WMFArticleContainerViewController ()
<WMFWebViewControllerDelegate,
 WMFArticleViewControllerDelegate,
 UINavigationControllerDelegate,
 WMFPreviewControllerDelegate,
 WMFArticleHeaderImageGalleryViewControllerDelegate,
 WMFImageGalleryViewControllerDelegate,
 WMFTableOfContentsViewControllerDelegate
>

// Data
@property (nonatomic, strong) MWKSavedPageList* savedPageList;
@property (nonatomic, strong) MWKHistoryList* recentPages;
@property (nonatomic, strong) MWKDataStore* dataStore;
@property (nonatomic, strong) WMFSaveButtonController* saveButtonController;

// Fetchers
@property (nonatomic, strong) WMFArticlePreviewFetcher* articlePreviewFetcher;
@property (nonatomic, strong) WMFArticleFetcher* articleFetcher;
@property (nonatomic, strong, nullable) AnyPromise* articleFetcherPromise;

// Children
@property (nonatomic, strong, readwrite) WMFArticleViewController* articleViewController;
@property (nonatomic, strong) WebViewController* webViewController;
@property (nonatomic, strong) WMFArticleHeaderImageGalleryViewController* headerGallery;
@property (nonatomic, strong) WMFArticleListCollectionViewController* readMoreListViewController;
@property (nonatomic, strong, null_resettable) WMFTableOfContentsViewController* tableOfContentsViewController;

// Logging
@property (strong, nonatomic, nullable) WMFShareFunnel* shareFunnel;
@property (strong, nonatomic, nullable) WMFShareOptionsController* shareOptionsController;

// Views
@property (nonatomic, strong) MASConstraint* headerHeightConstraint;


// WIP
@property (nonatomic, weak, readonly) UIViewController<WMFArticleContentController>* currentArticleController;
@property (nonatomic, strong, nullable) WMFPreviewController* previewController;

@end

@implementation WMFArticleContainerViewController
@synthesize article = _article;

#pragma mark - Setup

+ (instancetype)articleContainerViewControllerWithDataStore:(MWKDataStore*)dataStore
                                                recentPages:(MWKHistoryList*)recentPages
                                                 savedPages:(MWKSavedPageList*)savedPages {
    return [[self alloc] initWithDataStore:dataStore recentPages:recentPages savedPages:savedPages];
}

- (instancetype)initWithDataStore:(MWKDataStore*)dataStore
                      recentPages:(MWKHistoryList*)recentPages
                       savedPages:(MWKSavedPageList*)savedPages {
    self = [super init];
    if (self) {
        self.savedPageList = savedPages;
        self.recentPages   = recentPages;
        self.dataStore     = dataStore;
        [self commonInit];
    }
    return self;
}

- (instancetype __nullable)initWithCoder:(NSCoder*)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    // prevents the toolbar from being rendered above where the tabbar used to be
    self.hidesBottomBarWhenPushed = YES;
    [self setupToolbar];
}

#pragma mark - Accessors

- (NSString*)description {
    return [NSString stringWithFormat:@"%@ %@", [super description], self.article.title];
}

- (UIViewController<WMFArticleContentController>*)currentArticleController {
    return self.webViewController;
}

- (void)setArticle:(MWKArticle* __nullable)article {
    if (WMF_EQUAL(_article, isEqualToArticle:, article)) {
        return;
    }

    self.shareFunnel            = nil;
    self.shareOptionsController = nil;
    self.tableOfContentsViewController = nil;

    [self.articlePreviewFetcher cancelFetchForPageTitle:_article.title];
    [self.articleFetcher cancelFetchForPageTitle:_article.title];

    [self setAndObserveArticle:article];

    self.saveButtonController.title = article.title;

    if (_article) {
        self.shareFunnel            = [[WMFShareFunnel alloc] initWithArticle:_article];
        self.shareOptionsController =
            [[WMFShareOptionsController alloc] initWithArticle:self.article shareFunnel:self.shareFunnel];
    }

    [self fetchArticle];
}

- (void)setAndObserveArticle:(MWKArticle*)article {
    [self unobserveArticleUpdates];

    _article = article;

    [self observeArticleUpdates];

    [self updateChildrenWithArticle];
}

- (WMFArticleListCollectionViewController*)readMoreListViewController {
    if (!_readMoreListViewController) {
        _readMoreListViewController             = [[WMFSelfSizingArticleListCollectionViewController alloc] init];
        _readMoreListViewController.recentPages = self.savedPageList.dataStore.userDataStore.historyList;
        _readMoreListViewController.dataStore   = self.savedPageList.dataStore;
        _readMoreListViewController.savedPages  = self.savedPageList;
        WMFRelatedTitleListDataSource* relatedTitlesDataSource =
            [[WMFRelatedTitleListDataSource alloc] initWithTitle:self.article.title
                                                       dataStore:self.savedPageList.dataStore
                                                   savedPageList:self.savedPageList
                                                     resultLimit:3];
        // TODO: fetch lazily
        [relatedTitlesDataSource fetch];
        // TEMP: configure extract chars
        _readMoreListViewController.dataSource = relatedTitlesDataSource;
    }
    return _readMoreListViewController;
}

- (WMFArticlePreviewFetcher*)articlePreviewFetcher {
    if (!_articlePreviewFetcher) {
        _articlePreviewFetcher = [[WMFArticlePreviewFetcher alloc] init];
    }
    return _articlePreviewFetcher;
}

- (WMFArticleFetcher*)articleFetcher {
    if (!_articleFetcher) {
        _articleFetcher = [[WMFArticleFetcher alloc] initWithDataStore:self.dataStore];
    }
    return _articleFetcher;
}

- (WebViewController*)webViewController {
    if (!_webViewController) {
        _webViewController                      = [WebViewController wmf_initialViewControllerFromClassStoryboard];
        _webViewController.delegate             = self;
        _webViewController.headerViewController = self.headerGallery;
        // TODO: add "last edited by" & "wikipedia logo"
        [_webViewController setFooterViewControllers:@[self.readMoreListViewController]];
    }
    return _webViewController;
}

- (WMFArticleHeaderImageGalleryViewController*)headerGallery {
    if (!_headerGallery) {
        _headerGallery          = [[WMFArticleHeaderImageGalleryViewController alloc] init];
        _headerGallery.delegate = self;
    }
    return _headerGallery;
}


- (WMFTableOfContentsViewController*)tableOfContentsViewController{
    if(!_tableOfContentsViewController){
        _tableOfContentsViewController = [[WMFTableOfContentsViewController alloc] initWithSectionList:self.article.sections delegate:self];
    }
    return _tableOfContentsViewController;
}

// TEMP: delete!
- (WMFArticleViewController*)articleViewController {
    return nil;
}

- (void)updateChildrenWithArticle {
    // HAX: Need to check the window to see if we are on screen, isViewLoaded is not enough.
    // see http://stackoverflow.com/a/2777460/48311
    if ([self isViewLoaded] && self.view.window) {
        self.articleViewController.article = self.article;
        self.webViewController.article     = self.article;
        [self.headerGallery setImagesFromArticle:self.article];
    }
}

#pragma mark - Article Notifications

- (void)observeArticleUpdates {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:MWKArticleSavedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(articleUpdatedWithNotification:) name:MWKArticleSavedNotification object:nil];
}

- (void)unobserveArticleUpdates {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:MWKArticleSavedNotification object:nil];
}

- (void)articleUpdatedWithNotification:(NSNotification*)note {
    MWKArticle* article = note.userInfo[MWKArticleKey];
    if ([self.article.title isEqualToTitle:article.title]) {
        [self setAndObserveArticle:article];
    }
}

#pragma mark - Toolbar

- (void)setupToolbar {
    UIBarButtonItem* saveToolbarItem = [self saveToolbarItem];
    self.toolbarItems = [@[[self flexibleSpaceToolbarItem], [self refreshToolbarItem],
                           [self paddingToolbarItem], [self shareToolbarItem],
                           [self paddingToolbarItem], saveToolbarItem] wmf_reverseArrayIfApplicationIsRTL];
    self.saveButtonController =
    [[WMFSaveButtonController alloc] initWithButton:(UIButton*)saveToolbarItem.customView
                                      savedPageList:self.savedPageList
                                              title:self.article.title];
    
    if (!self.article.isMain) {
        self.navigationItem.rightBarButtonItem = [self tableOfContentsToolbarItem];
    }
}

- (UIBarButtonItem*)paddingToolbarItem {
    UIBarButtonItem* item =
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    item.width = 10.f;
    return item;
}

- (UIBarButtonItem*)saveToolbarItem {
    return [UIBarButtonItem wmf_buttonType:WMFButtonTypeBookmark handler:nil];
}

- (UIBarButtonItem*)refreshToolbarItem {
    @weakify(self);
    return [UIBarButtonItem wmf_buttonType:WMFButtonTypeReload handler:^(id _Nonnull sender) {
        @strongify(self);
        [self fetchArticle];
    }];
}

- (UIBarButtonItem*)flexibleSpaceToolbarItem {
    return [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                         target:nil
                                                         action:NULL];
}

- (UIBarButtonItem*)shareToolbarItem {
    @weakify(self);
    return [UIBarButtonItem wmf_buttonType:WMFButtonTypeShare handler:^(id sender){
        @strongify(self);
        [self shareArticleWithTextSnippet:[self.webViewController selectedText] fromButton:sender];
    }];
}

- (UIBarButtonItem*)tableOfContentsToolbarItem {
    @weakify(self);
    return [UIBarButtonItem wmf_buttonType:WMFButtonTypeTableOfContents handler:^(id sender){
        @strongify(self);
        [self.tableOfContentsViewController selectAndScrollToSection:[self.webViewController currentVisibleSection] animated:NO];
        [self presentViewController:self.tableOfContentsViewController animated:YES completion:NULL];
    }];
}


#pragma mark - ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    [self addChildViewController:self.webViewController];
    [self.view addSubview:self.webViewController.view];
    [self.webViewController.view mas_makeConstraints:^(MASConstraintMaker* make) {
        make.leading.trailing.top.and.bottom.equalTo(self.view);
    }];
    [self.webViewController didMoveToParentViewController:self];

    if (self.article) {
        [self updateChildrenWithArticle];
    }
}

#pragma mark - Article Navigation

- (void)showArticleViewControllerForTitle:(MWKTitle*)title {
    MWKArticle* article                          = [self.dataStore articleWithTitle:title];
    WMFArticleContainerViewController* articleVC =
        [[WMFArticleContainerViewController alloc] initWithDataStore:self.dataStore
                                                         recentPages:self.recentPages
                                                          savedPages:self.savedPageList];
    articleVC.article = article;
    [self showArticleViewController:articleVC];
}

- (void)showArticleViewController:(WMFArticleContainerViewController*)articleVC {
    [self.recentPages addPageToHistoryWithTitle:articleVC.article.title
                                discoveryMethod:MWKHistoryDiscoveryMethodLink];
    [self.navigationController pushViewController:articleVC animated:YES];
}

#pragma mark - Article Fetching

- (void)fetchArticle {
    [self fetchArticleForTitle:self.article.title];
}

- (void)fetchArticleForTitle:(MWKTitle*)title {
    @weakify(self);
    [self.articlePreviewFetcher fetchArticlePreviewForPageTitle:title progress:NULL].then(^(MWKArticlePreview* articlePreview){
        @strongify(self);
        [self unobserveArticleUpdates];
        AnyPromise* fullArticlePromise = [self.articleFetcher fetchArticleForPageTitle:title progress:NULL];
        self.articleFetcherPromise = fullArticlePromise;
        return fullArticlePromise;
    }).then(^(MWKArticle* article){
        @strongify(self);
        [self setAndObserveArticle:article];
    }).catch(^(NSError* error){
        @strongify(self);
        if ([error wmf_isWMFErrorOfType:WMFErrorTypeRedirected]) {
            [self fetchArticleForTitle:[[error userInfo] wmf_redirectTitle]];
        } else if (!self.presentingViewController) {
            // only do error handling if not presenting gallery
            DDLogError(@"Article Fetch Error: %@", [error localizedDescription]);
        }
    }).finally(^{
        @strongify(self);
        self.articleFetcherPromise = nil;
        [self observeArticleUpdates];
    });
}

#pragma mark - Share

- (void)shareArticleWithTextSnippet:(nullable NSString*)text fromButton:(nullable UIButton*)button {
    if (text.length == 0) {
        text = [self.article shareSnippet];
    }
    [self.shareFunnel logShareButtonTappedResultingInSelection:text];
    [self.shareOptionsController presentShareOptionsWithSnippet:text inViewController:self fromView:button];
}

#pragma mark - WebView Transition

- (void)showWebViewAtFragment:(NSString*)fragment animated:(BOOL)animated {
    [self.webViewController scrollToFragment:fragment];
}

#pragma mark - WMFArticleViewControllerDelegate

- (void)articleNavigator:(id<WMFArticleNavigation> __nullable)sender
      didTapCitationLink:(NSString* __nonnull)citationFragment {
    if (self.article.isCached) {
        [self showCitationWithFragment:citationFragment];
    } else {
        // TODO: fetch all sections before attempting to parse citations natively
//        if (!self.articleFetcherPromise) {
//            [self fetchArticle];
//        }
//        @weakify(self);
//        self.articleFetcherPromise.then(^(MWKArticle* _) {
//            @strongify(self);
//            [self showCitationWithFragment:citationFragment];
//        });
    }
}

- (void)articleViewController:(WMFArticleViewController* __nonnull)articleViewController
    didTapSectionWithFragment:(NSString* __nonnull)fragment {
    [self showWebViewAtFragment:fragment animated:YES];
}

- (void)showCitationWithFragment:(NSString*)fragment {
    // TODO: parse citations natively, then show citation popup control
//    NSParameterAssert(self.article.isCached);
//    MWKCitation* tappedCitation = [self.article.citations bk_match:^BOOL (MWKCitation* citation) {
//        return [citation.citationIdentifier isEqualToString:fragment];
//    }];
//    DDLogInfo(@"Tapped citation %@", tappedCitation);
//    if (!tappedCitation) {
//        DDLogWarn(@"Failed to parse citation for article %@", self.article);
//    }

    // TEMP: show webview until we figure out what to do w/ ReferencesVC
    [self showWebViewAtFragment:fragment animated:YES];
}

- (void)articleNavigator:(id<WMFArticleNavigation> __nullable)sender
        didTapLinkToPage:(MWKTitle* __nonnull)title {
    [self presentPopupForTitle:title];
}

- (void)articleNavigator:(id<WMFArticleNavigation> __nullable)sender
      didTapExternalLink:(NSURL* __nonnull)externalURL {
    [self wmf_openExternalUrl:externalURL];
}

#pragma mark - WMFArticleListItemController

- (WMFArticleControllerMode)mode {
    // TEMP: WebVC (and currentArticleController) will eventually conform to this
    return self.articleViewController.mode;
}

- (void)setMode:(WMFArticleControllerMode)mode animated:(BOOL)animated {
    // TEMP: WebVC (and currentArticleController) will eventually conform to this
    [self.articleViewController setMode:mode animated:animated];
}

#pragma mark - WMFWebViewControllerDelegate

- (void)webViewController:(WebViewController*)controller didTapOnLinkForTitle:(MWKTitle*)title {
    [self presentPopupForTitle:title];
}

- (void)webViewController:(WebViewController*)controller didSelectText:(NSString*)text {
    [self.shareFunnel logHighlight];
}

- (void)webViewController:(WebViewController*)controller didTapShareWithSelectedText:(NSString*)text {
    [self shareArticleWithTextSnippet:text fromButton:nil];
}

#pragma mark - Popup

- (void)presentPopupForTitle:(MWKTitle*)title {
    //TODO: Disabling pop ups until Popup VC is redesigned.
    //Renable preview when this true
    [self showArticleViewControllerForTitle:title];

    return;

//    WMFPreviewController* previewController = [[WMFPreviewController alloc] initWithPreviewViewController:vc containingViewController:self tabBarController:self.navigationController.tabBarController];
//    previewController.delegate = self;
//    [previewController presentPreviewAnimated:YES];
//
//    self.previewController = previewController;
}

#pragma mark - Analytics

- (NSString*)analyticsName {
    return [self.article analyticsName];
}

#pragma mark - TableOfContentsViewControllerDelegate

- (void)tableOfContentsController:(WMFTableOfContentsViewController *)controller didSelectSection:(MWKSection *)section{
    //Don't dismiss immediately - it looks jarring - let the user see the ToC selection before dismissing
    dispatchOnMainQueueAfterDelayInSeconds(0.25, ^{
        [self dismissViewControllerAnimated:YES completion:NULL];
        [self.webViewController scrollToSection:section];
    });
}

- (void)tableOfContentsControllerDidCancel:(WMFTableOfContentsViewController *)controller{
    [self dismissViewControllerAnimated:YES completion:NULL];
}


#pragma mark - WMFPreviewControllerDelegate

- (void)   previewController:(WMFPreviewController*)previewController
    didPresentViewController:(UIViewController*)viewController {
    self.previewController = nil;

    /* HACK: for some reason, the view controller is unusable when it comes back from the preview.
     * Trying to display it causes much ballyhooing about constraints.
     * Work around, make another view controller and push it instead.
     */
    WMFArticleContainerViewController* previewed = (id)viewController;
    [self showArticleViewControllerForTitle:previewed.article.title];
}

- (void)   previewController:(WMFPreviewController*)previewController
    didDismissViewController:(UIViewController*)viewController {
    self.previewController = nil;
}

#pragma mark - WMFArticleHeadermageGalleryViewControllerDelegate

- (void)headerImageGallery:(WMFArticleHeaderImageGalleryViewController* __nonnull)gallery
     didSelectImageAtIndex:(NSUInteger)index {
    NSParameterAssert(![self.presentingViewController isKindOfClass:[WMFImageGalleryViewController class]]);
    WMFImageGalleryViewController* fullscreenGallery = [[WMFImageGalleryViewController alloc] initWithArticle:nil];
    fullscreenGallery.delegate = self;
    if (self.article.isCached) {
        fullscreenGallery.article     = self.article;
        fullscreenGallery.currentPage = index;
    } else {
        // TODO: simplify the "isCached"/"fetch if needed" logic here
        if (!self.articleFetcherPromise) {
            [self fetchArticle];
        }
        [fullscreenGallery setArticleWithPromise:self.articleFetcherPromise];
    }
    [self presentViewController:fullscreenGallery animated:YES completion:nil];
}

#pragma mark - WMFImageGalleryViewControllerDelegate

- (void)willDismissGalleryController:(WMFImageGalleryViewController* __nonnull)gallery {
    self.headerGallery.currentPage = gallery.currentPage;
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

NS_ASSUME_NONNULL_END
