#import "TreeSnapshot.h"
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

// Read the same active application handles used by XCTest. No app-specific
// selectors, external service, accessibility setting changes or UI actions.
static id Invoke(id object, NSString *name) {
  SEL selector = NSSelectorFromString(name);
  return [object respondsToSelector:selector] ? ((id(*)(id, SEL))objc_msgSend)(object, selector) : nil;
}
static NSString *Role(XCUIElementType type) {
  switch (type) {
    case XCUIElementTypeApplication: return @"application";
    case XCUIElementTypeWindow: return @"window";
    case XCUIElementTypeButton: return @"button";
    case XCUIElementTypeStaticText: return @"text";
    case XCUIElementTypeTextField: return @"text_field";
    case XCUIElementTypeSecureTextField: return @"secure_text_field";
    case XCUIElementTypeTextView: return @"text_view";
    case XCUIElementTypeSearchField: return @"search_field";
    case XCUIElementTypeImage: return @"image";
    case XCUIElementTypeLink: return @"link";
    case XCUIElementTypeSwitch: return @"switch";
    case XCUIElementTypeSlider: return @"slider";
    case XCUIElementTypeScrollView: return @"scroll_view";
    case XCUIElementTypeTable: return @"table";
    case XCUIElementTypeCell: return @"cell";
    case XCUIElementTypeCollectionView: return @"collection_view";
    case XCUIElementTypeNavigationBar: return @"navigation_bar";
    case XCUIElementTypeTabBar: return @"tab_bar";
    case XCUIElementTypeToolbar: return @"toolbar";
    case XCUIElementTypeAlert: return @"alert";
    case XCUIElementTypeSheet: return @"sheet";
    case XCUIElementTypeKeyboard: return @"keyboard";
    case XCUIElementTypeKey: return @"key";
    case XCUIElementTypePicker: return @"picker";
    case XCUIElementTypePickerWheel: return @"picker_wheel";
    case XCUIElementTypeOther: return @"other";
    default: return [NSString stringWithFormat:@"type_%lu", (unsigned long)type];
  }
}
static NSDictionary *Encode(id<XCUIElementSnapshot> node, NSUInteger depth,
                            NSUInteger *count, BOOL *truncated) {
  if (depth > 40 || *count >= 1500) { *truncated = YES; return nil; }
  NSUInteger index = (*count)++;
  CGRect frame = node.frame;
  NSMutableDictionary *result = [@{
    @"id": [NSString stringWithFormat:@"n%lu", (unsigned long)index],
    @"type": @(node.elementType), @"role": Role(node.elementType), @"label": node.label ?: @"",
    @"identifier": node.identifier ?: @"", @"enabled": @(node.enabled),
    @"selected": @(node.selected),
    @"rect": @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
                @"width": @(frame.size.width), @"height": @(frame.size.height)}
  } mutableCopy];
  // Never return a secure text field's contents.
  if (node.elementType != XCUIElementTypeSecureTextField &&
      ([node.value isKindOfClass:NSString.class] || [node.value isKindOfClass:NSNumber.class])) {
    result[@"value"] = node.value;
  }
  NSMutableArray *children = [NSMutableArray array];
  for (id<XCUIElementSnapshot> child in node.children) {
    NSDictionary *encoded = Encode(child, depth + 1, count, truncated);
    if (!encoded) break;
    [children addObject:encoded];
  }
  if (children.count) result[@"children"] = children;
  return result;
}
NSDictionary *SoloReadAccessibilityTree(void) {
  @try {
    id client = Invoke(XCUIDevice.sharedDevice, @"accessibilityInterface");
    if (!client) client = Invoke(NSClassFromString(@"XCAXClient_iOS"), @"sharedClient");
    NSArray *active = Invoke(client, @"activeApplications");
    if (![active isKindOfClass:NSArray.class] || !active.count)
      return @{@"status": @"unavailable", @"reason": @"active_app_unavailable"};
    NSMutableArray *roots = [NSMutableArray array];
    NSUInteger count = 0;
    BOOL truncated = NO;
    for (id handle in active) {
      SEL pidSelector = NSSelectorFromString(@"processIdentifier");
      if (![handle respondsToSelector:pidSelector]) continue;
      pid_t pid = ((pid_t(*)(id,SEL))objc_msgSend)(handle, pidSelector);
      id tracker = Invoke(client, @"applicationProcessTracker");
      SEL appSelector = NSSelectorFromString(@"monitoredApplicationWithProcessIdentifier:");
      if (![tracker respondsToSelector:appSelector]) continue;
      XCUIApplication *app = ((id(*)(id,SEL,pid_t))objc_msgSend)(tracker, appSelector, pid);
      if (!app) continue;
      NSError *error = nil;
      id<XCUIElementSnapshot> snapshot = [app snapshotWithError:&error];
      if (!snapshot || error) continue;
      NSDictionary *root = Encode(snapshot, 0, &count, &truncated);
      if (root) [roots addObject:@{@"app_id": Invoke(app, @"bundleID") ?: @"", @"root": root}];
    }
    CGSize viewport = UIScreen.mainScreen.bounds.size;
    return @{@"status": roots.count ? @"available" : @"unavailable",
      @"reason": roots.count ? @"" : @"snapshot_unavailable",
      @"source": @"xctest", @"coordinate_space": @"screen_points",
      @"captured_at_ms": @((long long)(NSDate.date.timeIntervalSince1970 * 1000)),
      @"truncated": @(truncated), @"partial": @((BOOL)(roots.count != active.count)),
      @"viewport": @{@"width": @(viewport.width), @"height": @(viewport.height)},
      @"node_count": @(count), @"applications": roots};
  } @catch (NSException *exception) {
    return @{@"status": @"unavailable", @"reason": @"snapshot_exception"};
  }
}
