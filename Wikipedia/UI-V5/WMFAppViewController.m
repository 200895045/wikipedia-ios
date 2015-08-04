
#import "WMFAppViewController.h"
#import "SessionSingleton.h"
#import "WMFStyleManager.h"
#import "WMFSearchViewController.h"
#import "WMFArticleListCollectionViewController.h"
#import "DataMigrationProgressViewController.h"
#import "WMFSavedPagesDataSource.h"
#import "WMFRecentPagesDataSource.h"
#import "UIStoryboard+WMFExtensions.h"
#import "UITabBarController+WMFExtensions.h"
#import <Masonry/Masonry.h>
#import "MediaWikiKit.h"
#import "UIFont+WMFStyle.h"
#import "NSString+WMFGlyphs.h"

typedef NS_ENUM (NSUInteger, WMFAppTabType) {
    WMFAppTabTypeNearby = 0,
    WMFAppTabTypeSaved,
    WMFAppTabTypeRecent
};


@interface WMFAppViewController ()<WMFSearchViewControllerDelegate, UITabBarControllerDelegate>
@property (strong, nonatomic) IBOutlet UIView* searchContainerView;
@property (strong, nonatomic) IBOutlet UIView* tabControllerContainerView;

@property (nonatomic, strong) IBOutlet UIView* splashView;

@property (nonatomic, strong) UITabBarController* rootTabBarController;

@property (nonatomic, strong, readonly) WMFArticleListCollectionViewController* savedArticlesViewController;
@property (nonatomic, strong, readonly) WMFArticleListCollectionViewController* recentArticlesViewController;

@property (nonatomic, strong) WMFSearchViewController* searchViewController;

@property (nonatomic, strong) SessionSingleton* session;

@end

@implementation WMFAppViewController

#pragma mark - Setup

- (void)loadMainUI {
    [self configureTabController];
    [self configureSearchViewController];
    [self configureSavedViewController];
    [self configureRecentViewController];
    [self updateTabBarVisibilityBasedOnSearchState:self.searchViewController.state];
}

- (void)configureTabController {
    self.rootTabBarController.delegate = self;
}

- (void)configureSearchViewController {
    self.searchViewController.delegate      = self;
    self.searchViewController.searchSite    = [self.session searchSite];
    self.searchViewController.dataStore     = self.session.dataStore;
    self.searchViewController.userDataStore = self.session.userDataStore;
}

- (void)configureArticleListController:(WMFArticleListCollectionViewController*)controller {
    controller.dataStore   = self.session.dataStore;
    controller.savedPages  = self.session.userDataStore.savedPageList;
    controller.recentPages = self.session.userDataStore.historyList;
}

- (void)configureSavedViewController {
    [self configureArticleListController:self.savedArticlesViewController];
    if (!self.savedArticlesViewController.dataSource) {
        self.savedArticlesViewController.dataSource =
            [[WMFSavedPagesDataSource alloc] initWithSavedPagesList:[self userDataStore].savedPageList];
    }
}

- (void)configureRecentViewController {
    [self configureArticleListController:self.recentArticlesViewController];
    if (!self.recentArticlesViewController.dataSource) {
        self.recentArticlesViewController.dataSource =
            [[WMFRecentPagesDataSource alloc] initWithRecentPagesList:[self userDataStore].historyList];
    }
}

#pragma mark - Public

+ (WMFAppViewController*)initialAppViewControllerFromDefaultStoryBoard {
    return [[UIStoryboard wmf_appRootStoryBoard] instantiateInitialViewController];
}

- (void)launchAppInWindow:(UIWindow*)window {
    WMFStyleManager* manager = [WMFStyleManager new];
    [manager applyStyleToWindow:window];
    [WMFStyleManager setSharedStyleManager:manager];

    [window setRootViewController:self];
    [window makeKeyAndVisible];
}

- (void)resumeApp {
    //TODO: restore any UI, show Today
}

#pragma mark - Utilities

- (UINavigationController*)navigationControllerForTab:(WMFAppTabType)tab {
    return (UINavigationController*)[self.rootTabBarController viewControllers][tab];
}

- (UIViewController*)rootViewControllerForTab:(WMFAppTabType)tab {
    return [[[self navigationControllerForTab:tab] viewControllers] firstObject];
}

#pragma mark - Accessors

- (SessionSingleton*)session {
    if (!_session) {
        _session = [SessionSingleton sharedInstance];
    }

    return _session;
}

- (MWKDataStore*)dataStore {
    return self.session.dataStore;
}

- (MWKUserDataStore*)userDataStore {
    return self.session.userDataStore;
}

- (WMFArticleListCollectionViewController*)savedArticlesViewController {
    return (WMFArticleListCollectionViewController*)[self rootViewControllerForTab:WMFAppTabTypeSaved];
}

- (WMFArticleListCollectionViewController*)recentArticlesViewController {
    return (WMFArticleListCollectionViewController*)[self rootViewControllerForTab:WMFAppTabTypeRecent];
}

#pragma mark - UIViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self showSplashView];

    [self runDataMigrationIfNeededWithCompletion:^{
        [self hideSplashViewAnimated:YES];
        [self loadMainUI];
    }];
}

- (void)prepareForSegue:(UIStoryboardSegue*)segue sender:(id)sender {
    if ([segue.destinationViewController isKindOfClass:[WMFSearchViewController class]]) {
        self.searchViewController = segue.destinationViewController;
        [self configureSearchViewController];
    }
    if ([segue.destinationViewController isKindOfClass:[UITabBarController class]]) {
        self.rootTabBarController = segue.destinationViewController;
        [self configureTabController];
    }
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

#pragma mark - Splash

- (void)showSplashView {
    self.splashView.hidden          = NO;
    self.splashView.layer.transform = CATransform3DIdentity;
    self.splashView.alpha           = 1.0;
}

- (void)hideSplashViewAnimated:(BOOL)animated {
    NSTimeInterval duration = animated ? 0.3 : 0.0;

    [UIView animateWithDuration:duration animations:^{
        self.splashView.layer.transform = CATransform3DMakeScale(10.0f, 10.0f, 1.0f);
        self.splashView.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.splashView.hidden = YES;
        self.splashView.layer.transform = CATransform3DIdentity;
    }];
}

- (BOOL)isShowingSplashView {
    return self.splashView.hidden == NO;
}

#pragma mark - Migration

- (void)runDataMigrationIfNeededWithCompletion:(dispatch_block_t)completion {
    DataMigrationProgressViewController* migrationVC = [[DataMigrationProgressViewController alloc] init];
    [migrationVC removeOldDataBackupIfNeeded];

    if (![migrationVC needsMigration]) {
        if (completion) {
            completion();
        }
        return;
    }

    [self presentViewController:migrationVC animated:YES completion:^{
        [migrationVC runMigrationWithCompletion:^(BOOL migrationCompleted) {
            [migrationVC dismissViewControllerAnimated:YES completion:NULL];
            if (completion) {
                completion();
            }
        }];
    }];
}

- (void)rootTabBarController:(UITabBarController*)rootTabBarController didSelectViewController:(UIViewController*)viewController {
    WMFAppTabType tab = [[rootTabBarController viewControllers] indexOfObject:viewController];

    switch (tab) {
        case WMFAppTabTypeNearby: {
            //TODO: configure Nearby
        }
        break;
        case WMFAppTabTypeSaved: {
            [self configureSavedViewController];
        }
        break;
        case WMFAppTabTypeRecent: {
            [self configureRecentViewController];
        }
        break;
    }
}

#pragma mark - WMFSearchViewControllerDelegate

- (void)searchController:(WMFSearchViewController*)controller searchStateDidChange:(WMFSearchState)state {
    [self updateTabBarVisibilityBasedOnSearchState:state];
}

- (void)updateTabBarVisibilityBasedOnSearchState:(WMFSearchState)state {
    switch (state) {
        case WMFSearchStateInactive: {
            self.rootTabBarController.view.hidden                  = NO;
            self.tabControllerContainerView.userInteractionEnabled = YES;
            [self.rootTabBarController wmf_setTabBarVisible:YES animated:YES completion:NULL];
        }
        break;
        case WMFSearchStateActive: {
            @weakify(self);
            [self.rootTabBarController wmf_setTabBarVisible:NO animated:YES completion:^{
                @strongify(self);
                self.rootTabBarController.view.hidden = YES;
                self.tabControllerContainerView.userInteractionEnabled = NO;
            }];
        }
        break;
    }
}

@end
