//  Created by Monte Hurd on 10/9/14.
//  Copyright (c) 2014 Wikimedia Foundation. Provided under MIT-style license; please copy and modify!

#import <Foundation/Foundation.h>
#import "FetcherBase.h"

@class AFHTTPRequestOperationManager, ArticleFetcher, AFHTTPRequestOperation, MWKTitle;

typedef void (^ ArticleFetcherProgress)(CGFloat progress);
typedef void (^ ArticleFetcherCompletion)(MWKArticle* article, NSError* error);


@interface ArticleFetcher : FetcherBase

- (AFHTTPRequestOperation*)fetchSectionsForTitle:(MWKTitle*)title
                                     inDataStore:(MWKDataStore*)store
                                     withManager:(AFHTTPRequestOperationManager*)manager
                                   progressBlock:(ArticleFetcherProgress)progress
                                 completionBlock:(ArticleFetcherCompletion)completion;




@end
