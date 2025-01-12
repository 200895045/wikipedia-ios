//
//  MWKArticleLeadSectionHTMLVisualTests.m
//  Wikipedia
//
//  Created by Brian Gerstle on 7/28/15.
//  Copyright (c) 2015 Wikimedia Foundation. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
#import <FBSnapshotTestCase/FBSnapshotTestCase.h>
#import "WMFTestFixtureUtilities.h"
#import "MWKArticle.h"
#import "XCTestCase+PromiseKit.h"
#import "WMFMinimalArticleContentCell.h"
#import "UIView+WMFDefaultNib.h"
#import "WMFArticleViewController.h"
#import "UIViewController+WMFStoryboardUtilities.h"
#import "FBSnapshotTestCase+WMFConvenience.h"

#define MOCKITO_SHORTHAND 1
#import <OCMockito/OCMockito.h>

@interface WMFArticleSummaryVisualTests : FBSnapshotTestCase
@property (nonatomic, strong) MWKArticle* article;
@property (nonatomic, strong) WMFArticleViewController* articleVC;
@end

@implementation WMFArticleSummaryVisualTests

- (void)setUp {
    [super setUp];
    self.articleVC = [WMFArticleViewController wmf_initialViewControllerFromClassStoryboard];
//    self.recordMode = YES;
}

- (void)tearDown {
    self.articleVC = nil;
    [super tearDown];
}

- (void)testPageWithCitations {
    [self verifySummaryForFixture:@"Exoplanet.mobileview" languageCode:@"en"];
}

- (void)testPageWithIPA {
    [self verifySummaryForFixture:@"Obama" languageCode:@"en"];
}

- (void)testPageWithRTL {
    NSData* mobileViewData =
        [[self wmf_bundle] wmf_dataFromContentsOfFile:@"MobileView/ar.m.wikipedia.org/تاج محل"
                                               ofType:@""];
    [self verifySummaryForFixtureData:
     [NSJSONSerialization JSONObjectWithData:mobileViewData options:0 error:nil]
                             langCode:@"ar"];
}

- (void)testPageWithChildlessParagraphs {
    NSData* mobileViewData =
        [[self wmf_bundle] wmf_dataFromContentsOfFile:@"MobileView/en.m.wiktionary.org/stationary"
                                               ofType:@""];
    [self verifySummaryForFixtureData:
     [NSJSONSerialization JSONObjectWithData:mobileViewData options:0 error:nil]
                             langCode:@"en"];
}

- (void)verifySummaryForFixture:(NSString*)fixtureFilename languageCode:(NSString*)langCode {
    NSDictionary* mobileViewJSON = [[self wmf_bundle] wmf_jsonFromContentsOfFile:fixtureFilename];
    [self verifySummaryForFixtureData:mobileViewJSON langCode:langCode];
}

- (void)verifySummaryForFixtureData:(NSDictionary*)mobileViewJSON langCode:(NSString*)langCode  {
    MWKTitle* title = [MWKTitle titleWithString:@"Title" site:[MWKSite siteWithDomain:@"wikipedia.org"
                                                                             language:langCode]];
    self.article = [[MWKArticle alloc] initWithTitle:title
                                           dataStore:nil
                                                dict:mobileViewJSON[@"mobileview"]];

    [self wmf_visuallyVerifyCellWithIdentifier:[WMFMinimalArticleContentCell wmf_nibName]
                                 fromTableView:self.articleVC.tableView
                           configuredWithBlock:^(UITableViewCell* cell){
        [(WMFMinimalArticleContentCell*)cell setAttributedText:self.article.summaryHTML];
    }];
}

@end
