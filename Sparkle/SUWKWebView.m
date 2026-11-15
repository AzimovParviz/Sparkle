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

@class SUWKWebView;

// Forward declarations so the subclass and wrapper know about each other
@interface SUWKWebView ()
- (void)performFindPanelAction:(id)sender;
- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item;
- (void)updateFindBarContainer;
@end

@interface SUInternalWKWebView : WKWebView
@property (nonatomic, weak) SUWKWebView *parentWebViewWrapper;
@end

@implementation SUInternalWKWebView

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)performFindPanelAction:(id)sender {
    [self.parentWebViewWrapper performFindPanelAction:sender];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    return [self.parentWebViewWrapper validateUserInterfaceItem:item];
}

- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    [self.parentWebViewWrapper updateFindBarContainer];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self.parentWebViewWrapper updateFindBarContainer];
}

@end


@interface SUWKWebView () <WKNavigationDelegate>
@end

@implementation SUWKWebView
{
    SUInternalWKWebView *_webView;
    NSScrollView *_scrollView;
    WKNavigation *_currentNavigation;
    NSArray<NSString *> *_customAllowedURLSchemes;
    NSTextFinder *_textFinder;
    NSString *_cachedPlainTextString;
    
    void (^_completionHandler)(NSError * _Nullable);
    
    BOOL _drawsWebViewBackground;
    BOOL _allowsLoadingExternalReferences;
}

static WKUserScript *makeUserScriptWithInjectedStyleSource(NSString *styleSource)
{
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
    NSMutableCharacterSet *allowedCharacterSet = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowedCharacterSet addCharactersInString:@"_.- "];
    if ([releaseString rangeOfCharacterFromSet:allowedCharacterSet.invertedSet].location != NSNotFound) {
        SULog(SULogLevelDefault, @"warning: App version '%@' has characters unsafe for injection.", releaseString);
        return nil;
    }
    
    NSString *scriptSource = [NSString stringWithFormat:
        @"document.querySelectorAll(\'[data-sparkle-version=\"%@\"]\')\n"
        @".forEach(installedVersionElement =>\n"
        @"installedVersionElement.classList.add('sparkle-installed-version')\n"
        @");", releaseString];
    
    return [[WKUserScript alloc] initWithSource:scriptSource injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
}

- (instancetype)initWithColorStyleSheetLocation:(NSURL *)colorStyleSheetLocation fontFamily:(NSString *)fontFamily fontPointSize:(int)fontPointSize javaScriptEnabled:(BOOL)javaScriptEnabled customAllowedURLSchemes:(NSArray<NSString *> *)customAllowedURLSchemes allowsLoadingExternalReferences:(BOOL)allowsLoadingExternalReferences installedVersion:(NSString *)installedVersion
{
    self = [super init];
    if (self != nil) {
        _drawsWebViewBackground = YES;
        _allowsLoadingExternalReferences = allowsLoadingExternalReferences;
        _cachedPlainTextString = @"";
        
        WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        configuration.preferences.javaScriptEnabled = javaScriptEnabled;
#pragma clang diagnostic pop
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = NO;
        
        NSError *colorStyleContentsError = nil;
        NSString *colorStyleContents = [NSString stringWithContentsOfURL:colorStyleSheetLocation encoding:NSUTF8StringEncoding error:&colorStyleContentsError];
        
        WKUserContentController *userContentController = [[WKUserContentController alloc] init];
        NSString *fontStyleContents = [NSString stringWithFormat:@"body { font-family: %@; font-size: %dpx; }", fontFamily, fontPointSize];
        
        NSString *finalStyleContents;
        if (colorStyleContents == nil) {
            finalStyleContents = fontStyleContents;
        } else {
            finalStyleContents = [NSString stringWithFormat:@"%@ %@", fontStyleContents, colorStyleContents];
        }
        
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
        _webView = [[SUInternalWKWebView alloc] initWithFrame:NSRectFromCGRect(CGRectMake(0, 0, 400, 300)) configuration:configuration];
        _webView.parentWebViewWrapper = self;
        _webView.navigationDelegate = self;
        _webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        // Wrap the WKWebView in an NSScrollView
        _scrollView = [[NSScrollView alloc] initWithFrame:NSRectFromCGRect(CGRectMake(0, 0, 400, 300))];
        _scrollView.documentView = _webView;
        _scrollView.hasVerticalScroller = YES;
        _scrollView.hasHorizontalScroller = NO;
        _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        
        // Initialize NSTextFinder and assign client to self
        _textFinder = [[NSTextFinder alloc] init];
        _textFinder.client = self;
        if (_scrollView != nil) {
            printf("i exist");
        } else {
            printf("for fucks sake");
        }
        _textFinder.findBarContainer = _scrollView;

        _customAllowedURLSchemes = customAllowedURLSchemes;
    }
    return self;
}

- (void)updateFindBarContainer {
    if (_webView.enclosingScrollView != nil) {
        _textFinder.findBarContainer = _webView.enclosingScrollView;
    }
}

- (NSView *)view
{
//    return _webView;
    return _scrollView;
}

static void SPULoadWebContent(BOOL allowsExternalReferences, WKUserContentController *userContentController, void (^loadHTMLContent)(void))
{
    if (allowsExternalReferences) {
        loadHTMLContent();
        return;
    }
    
    NSString *encodedContentRuleList =
        @"[{\"trigger\": { \"url-filter\": \".*\" }, \"action\": { \"type\": \"block\" } }]";
    
    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:@"sparkle-updater" encodedContentRuleList:encodedContentRuleList completionHandler:^(WKContentRuleList *contentRuleList, NSError *contentRuleListError) {
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
    _cachedPlainTextString = htmlString ?: @"";
    
    SPULoadWebContent(_allowsLoadingExternalReferences, _webView.configuration.userContentController, ^{
        self->_currentNavigation = [self->_webView loadHTMLString:htmlString baseURL:baseURL];
    });
}

- (void)loadData:(NSData *)data MIMEType:(NSString *)MIMEType textEncodingName:(NSString *)textEncodingName baseURL:(NSURL *)baseURL completionHandler:(void (^)(NSError * _Nullable))completionHandler
{
    _completionHandler = [completionHandler copy];
    _cachedPlainTextString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";

    SPULoadWebContent(_allowsLoadingExternalReferences, _webView.configuration.userContentController, ^{
        self->_currentNavigation = [self->_webView loadData:data MIMEType:MIMEType characterEncodingName:textEncodingName baseURL:baseURL];
    });
}

- (void)setDrawsBackground:(BOOL)drawsBackground
{
    if (_drawsWebViewBackground != drawsBackground) {
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
    
    if (!safeURL) {
        SULog(SULogLevelDefault, @"Blocked display of %@ URL which may be dangerous", requestURL.scheme);
        decisionHandler(WKNavigationActionPolicyCancel);
    } else {
        if (_completionHandler == nil) {
            if (!isAboutBlank) {
                [[NSWorkspace sharedWorkspace] openURL:requestURL];
            }
            decisionHandler(WKNavigationActionPolicyCancel);
        } else {
            decisionHandler(WKNavigationActionPolicyAllow);
        }
        
        [webView evaluateJavaScript:@"document.body.innerText" completionHandler:^(NSString * _Nullable text, NSError * _Nullable error) {
            if (text != nil) {
                _cachedPlainTextString = text;
            }
        }];
    }
}

#pragma mark - NSTextFinderClient Methods

- (NSString *)string {
    return _cachedPlainTextString;
}

- (NSRange)firstSelectedRange {
    return NSMakeRange(NSNotFound, 0);
}

- (void)setSelectedRanges:(NSArray<NSValue *> *)selectedRanges {
}

- (NSArray<NSValue *> *)rectsForCharacterRange:(NSRange)characterRange {
    return @[];
}

- (void)scrollRangeToVisible:(NSRange)range {
}

- (NSView *)contentViewAtIndex:(NSInteger)characterIndex effectiveRange:(NSRangePointer)outRange {
    return _webView;
}

#pragma mark - Menu & Action Handling

- (void)performFindPanelAction:(id)sender {
    if ([sender respondsToSelector:@selector(tag)]) {
        [_textFinder performAction:(NSTextFinderAction)[(__kindof NSView *)sender tag]];
    }
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    if ([item action] == @selector(performFindPanelAction:)) {
        return YES;
    }
    return NO;
}

@end

#endif /* SPARKLE_BUILD_UI_BITS */
