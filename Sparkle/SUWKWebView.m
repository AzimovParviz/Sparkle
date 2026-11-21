//
//  SUWKWebView.m
//  Sparkle
//
//  Created by Mayur Pawashe on 12/30/20.
//  Copyright © 2020 Sparkle Project. All rights reserved.
//

#if SPARKLE_BUILD_UI_BITS

#import "SUWKWebView.h"
#import "SUReleaseNotesCommon.h"
#import "SULog.h"
#import "SUErrors.h"

#import <WebKit/WebKit.h>

@interface WKWebView (Private)
- (void)_setDrawsBackground:(BOOL)drawsBackground;
- (void)_setDrawsTransparentBackground:(BOOL)drawsTransparentBackground;
@end

@interface SUWKWebView () <WKNavigationDelegate, NSSearchFieldDelegate>
- (void)performSearchAction:(id)sender;
@end

@implementation SUWKWebView
{
    NSView *_containerView;
    NSSearchField *_searchField;
    WKWebView *_webView;
    NSScrollView *_scrollView;
    WKNavigation *_currentNavigation;
    NSArray<NSString *> *_customAllowedURLSchemes;
    WKFindConfiguration *_findConfiguration;
    void (^_completionHandler)(NSError * _Nullable);
    BOOL _drawsWebViewBackground;
    BOOL _allowsLoadingExternalReferences;
}

static WKUserScript *makeUserScriptWithInjectedStyleSource(NSString *styleSource)
{
    // We must remove newlines when inserting the style source in this interpolated string below
    NSString *strippedStyleSource = [styleSource stringByReplacingOccurrencesOfString:@"\n" withString:@""];

    NSString *scriptSource = [NSString stringWithFormat:
        @"var style = document.createElement('style');\n"
        @"style.innerHTML = '%@'\n"
        @"var head = document.head;\n"
        @"if (head.firstChild) {"
        @"\tdocument.head.insertBefore(style, document.head.firstChild);\n"
        @"} else {\n"
        @"\tdocument.head.appendChild(style)\n"
        @"}", strippedStyleSource];

    return [[WKUserScript alloc] initWithSource:scriptSource injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
}

static WKUserScript *makeUserScriptForExposingCurrentRelease(NSString *releaseString)
{
    // Check that release string can be safely injected
    NSMutableCharacterSet *allowedCharacterSet = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowedCharacterSet addCharactersInString:@"_.- "];
    if ([releaseString rangeOfCharacterFromSet:allowedCharacterSet.invertedSet].location != NSNotFound) {
        SULog(SULogLevelDefault, @"warning: App version '%@' has characters unsafe for injection.", releaseString);
        return nil;
    }

    // This script adds the `sparkle-installed-version` class to all elements which have a matching `data-sparkle-version` attribute
    NSString *scriptSource = [NSString stringWithFormat:
        @"document.querySelectorAll('[data-sparkle-version=\"%@\"]')\n"
        @".forEach(installedVersionElement =>\n"
        @"installedVersionElement.classList.add('sparkle-installed-version')\n"
        @");", releaseString];

    return [[WKUserScript alloc] initWithSource:scriptSource injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
}

- (instancetype)initWithColorStyleSheetLocation:(NSURL *)colorStyleSheetLocation
                                      fontFamily:(NSString *)fontFamily
                                   fontPointSize:(int)fontPointSize
                               javaScriptEnabled:(BOOL)javaScriptEnabled
                         customAllowedURLSchemes:(NSArray<NSString *> *)customAllowedURLSchemes
                   allowsLoadingExternalReferences:(BOOL)allowsLoadingExternalReferences
                                installedVersion:(NSString *)installedVersion
{
    self = [super init];
    if (self != nil) {
        // Synchronize with web view defaulting to drawing background to avoid unnecessary invocations in -setDrawsBackground:
        _drawsWebViewBackground = YES;

        _allowsLoadingExternalReferences = allowsLoadingExternalReferences;
        _customAllowedURLSchemes = customAllowedURLSchemes;

        WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];

        // Note: this javaScriptEnabled property is deprecated in favor of another webpage preference property,
        // that involves implementing a delegate method that is only available on macOS 11.. to get it properly working.
        // To simplify things, just rely on deprecated property for now.
        // Future reader: if you change how JS is disabled, please be sure to test that JS code is properly disabled in HTML release notes.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        configuration.preferences.javaScriptEnabled = javaScriptEnabled;
#pragma clang diagnostic pop
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = NO;

        NSError *colorStyleContentsError = nil;
        NSString *colorStyleContents = [NSString stringWithContentsOfURL:colorStyleSheetLocation encoding:NSUTF8StringEncoding error:&colorStyleContentsError];

        WKUserContentController *userContentController = [[WKUserContentController alloc] init];

        NSString *fontStyleContents = [NSString stringWithFormat:@"body { font-family: %@; font-size: %dpx; }", fontFamily, fontPointSize];

        NSString *finalStyleContents = (colorStyleContents == nil)
            ? fontStyleContents
            : [NSString stringWithFormat:@"%@ %@", fontStyleContents, colorStyleContents];

        // Note: we can still execute javascript via WKUserScript even if javascript is otherwise disabled from the web content
        // In fact, we must execute javascript to properly inject our default CSS style into the DOM
        // Legacy WebView has exposed methods for custom stylesheets and default fonts,
        // but WKWebView seems to forgo that type of API surface in favor of user scripts like this
        WKUserScript *userScriptWithInjectedStyleSource = makeUserScriptWithInjectedStyleSource(finalStyleContents);
        if (userScriptWithInjectedStyleSource != nil) {
            [userContentController addUserScript:userScriptWithInjectedStyleSource];
        }

        WKUserScript *userScriptForExposingCurrentRelease = makeUserScriptForExposingCurrentRelease(installedVersion);
        if (userScriptForExposingCurrentRelease != nil) {
            [userContentController addUserScript:userScriptForExposingCurrentRelease];
        }

        configuration.userContentController = userContentController;

        // Create the web view with a non-zero initial frame or let autoresizing handle it
        NSRect initialFrame = NSMakeRect(0, 0, 400, 300);
        CGFloat searchBarHeight = 32.0;

        _containerView = [[NSView alloc] initWithFrame:initialFrame];
        _containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(8, initialFrame.size.height - searchBarHeight + 4, initialFrame.size.width - 16, 24)];
        _searchField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        _searchField.placeholderString = @"Find in page";
        _searchField.delegate = self;
        _searchField.target = self;
        _searchField.action = @selector(performSearchAction:);
        _searchField.sendsWholeSearchString = YES;
        _searchField.sendsSearchStringImmediately = NO;

        _webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, initialFrame.size.width, initialFrame.size.height - searchBarHeight) configuration:configuration];
        _webView.navigationDelegate = self;
        _webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        // Wrap the WKWebView in an NSScrollView
        _scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, initialFrame.size.width, initialFrame.size.height - searchBarHeight)];
        _scrollView.documentView = _webView;
        _scrollView.hasVerticalScroller = YES;
        _scrollView.hasHorizontalScroller = NO;
        _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        [_containerView addSubview:_scrollView];
        [_containerView addSubview:_searchField];

        _findConfiguration = [[WKFindConfiguration alloc] init];
        _findConfiguration.caseSensitive = NO;
        _findConfiguration.wraps = YES;
    }
    return self;
}

- (NSView *)view
{
    return _containerView;
}

- (void)performSearchAction:(id)sender
{
    NSString *query = _searchField.stringValue;
    if (query.length == 0) {
        return;
    }

    // Hold Shift while pressing Return to search backwards
    NSEventModifierFlags flags = [NSApp currentEvent].modifierFlags;
    _findConfiguration.backwards = ((flags & NSEventModifierFlagShift) != 0);

    [_webView findString:query
       withConfiguration:_findConfiguration
       completionHandler:^(WKFindResult * _Nonnull result) {
        if (!result.matchFound) {
            NSBeep();
        }
    }];
}

static void SPULoadWebContent(BOOL allowsExternalReferences, WKUserContentController *userContentController, void (^loadHTMLContent)(void))
{
    if (allowsExternalReferences) {
        loadHTMLContent();
        return;
    }

    // Block loading all external resources for signed appcasts & signed release notes
    NSString *encodedContentRuleList =
        @"[{\"trigger\": { \"url-filter\": \".*\" }, \"action\": { \"type\": \"block\" } }]";

    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:@"sparkle-updater"
                                                   encodedContentRuleList:encodedContentRuleList
                                                        completionHandler:^(WKContentRuleList *contentRuleList, NSError *contentRuleListError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (contentRuleList != nil) {
                [userContentController addContentRuleList:contentRuleList];
            }
            loadHTMLContent();
        });
    }];
}

- (void)loadString:(NSString *)htmlString baseURL:(NSURL * _Nullable)baseURL completionHandler:(void (^)(NSError * _Nullable))completionHandler
{
    _completionHandler = [completionHandler copy];

    SPULoadWebContent(_allowsLoadingExternalReferences, _webView.configuration.userContentController, ^{
        self->_currentNavigation = [self->_webView loadHTMLString:htmlString baseURL:baseURL];
    });
}

- (void)loadData:(NSData *)data MIMEType:(NSString *)MIMEType textEncodingName:(NSString *)textEncodingName baseURL:(NSURL *)baseURL completionHandler:(void (^)(NSError * _Nullable))completionHandler
{
    _completionHandler = [completionHandler copy];

    SPULoadWebContent(_allowsLoadingExternalReferences, _webView.configuration.userContentController, ^{
        self->_currentNavigation = [self->_webView loadData:data MIMEType:MIMEType characterEncodingName:textEncodingName baseURL:baseURL];
    });
}

- (void)setDrawsBackground:(BOOL)drawsBackground
{
    if (_drawsWebViewBackground != drawsBackground) {
        // Unfortunately we have to rely on a private API
        // FB7539179: https://github.com/feedback-assistant/reports/issues/81 | https://bugs.webkit.org/show_bug.cgi?id=155550
        // But it seems like others are already relying on it, passed App Review, and apps couldn't be broken due to compatibility
        // Note: before we were using _setDrawsTransparentBackground < macOS 10.12
        if ([_webView respondsToSelector:@selector(_setDrawsBackground:)]) {
            [_webView _setDrawsBackground:drawsBackground];
        }
        _drawsWebViewBackground = drawsBackground;
    }
}

- (void)stopLoading
{
    _completionHandler = nil;
    [_webView stopLoading];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    if (navigation == _currentNavigation) {
        if (_completionHandler != nil) {
            _completionHandler(nil);
            _completionHandler = nil;
        }
        _currentNavigation = nil;
    }
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    if (navigation == _currentNavigation) {
        if (_completionHandler != nil) {
            _completionHandler(error);
            _completionHandler = nil;
        }

        _currentNavigation = nil;
    }
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    if (_currentNavigation != nil) {
        if (_completionHandler != nil) {
            _completionHandler([NSError errorWithDomain:SUSparkleErrorDomain code:SUWebKitTerminationError userInfo:nil]);
            _completionHandler = nil;
        }
        _currentNavigation = nil;
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURLRequest *request = navigationAction.request;
    NSURL *requestURL = request.URL;
    BOOL isAboutBlank = NO;
    BOOL safeURL = SUReleaseNotesIsSafeURL(requestURL, _customAllowedURLSchemes, &isAboutBlank);

    // Do not allow redirects to dangerous protocols such as file://
    if (!safeURL) {
        SULog(SULogLevelDefault, @"Blocked display of %@ URL which may be dangerous", requestURL.scheme);
        decisionHandler(WKNavigationActionPolicyCancel);
    } else {
        // Ensure we're finished loading
        if (_completionHandler == nil) {
            if (!isAboutBlank) {
                [[NSWorkspace sharedWorkspace] openURL:requestURL];
            }
            decisionHandler(WKNavigationActionPolicyCancel);
        } else {
            decisionHandler(WKNavigationActionPolicyAllow);
        }
    }
}

@end

#endif /* SPARKLE_BUILD_UI_BITS */
