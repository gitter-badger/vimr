/**
* Tae Won Ha — @hataewon
*
* http://taewon.de
* http://qvacua.com
*
* See LICENSE
*/

#import "VRFileBrowserView.h"
#import "VRUtils.h"
#import "VRFileItemManager.h"
#import "VRMainWindowController.h"
#import "VRInvalidateCacheOperation.h"
#import "VRDefaultLogSetting.h"
#import "OakImageAndTextCell.h"
#import "NSArray+VR.h"
#import "VROutlineView.h"
#import "NSTableView+VR.h"


#define CONSTRAIN(fmt) [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:fmt options:0 metrics:nil views:views]];


static NSComparisonResult (^qNodeDirComparator)(NSNumber *, NSNumber *) =
    ^NSComparisonResult(NSNumber *node1IsDir, NSNumber *node2IsDir) {
      if (node1IsDir.boolValue) {
        return NSOrderedAscending;
      } else {
        return NSOrderedDescending;
      }
    };


@implementation VRNode

- (NSString *)description {
  NSMutableString *description = [NSMutableString stringWithFormat:@"<%@: ", NSStringFromClass([self class])];
  [description appendFormat:@"self.url=%@", self.url];
  [description appendFormat:@", self.name=%@", self.name];
  [description appendFormat:@", self.children=%@", self.children];
  [description appendFormat:@", self.dir=%d", self.dir];
  [description appendFormat:@", self.hidden=%d", self.hidden];
  [description appendFormat:@", self.item=%@", self.item];
  [description appendString:@">"];
  return description;
}

@end


@implementation VRFileBrowserView {
  NSMenuItem *_showHiddenMenuItem;
  NSMenuItem *_showFoldersFirstMenuItem;
  NSMenuItem *_syncWorkspaceWithPwdMenuItem;

  NSOperationQueue *_invalidateCacheQueue;

  VRNode *_rootNode;
  NSMutableSet *_expandedUrls;
}

#pragma mark Public
- (BOOL)syncWorkspaceWithPwd {
  return _syncWorkspaceWithPwdMenuItem.state == NSOnState;
}

- (void)setRootUrl:(NSURL *)rootUrl {
  _rootUrl = rootUrl;
  [self cacheInvalidated:nil];
}

- (instancetype)initWithRootUrl:(NSURL *)rootUrl {
  self = [super initWithFrame:CGRectZero];
  RETURN_NIL_WHEN_NOT_SELF

  _rootUrl = rootUrl;
  _invalidateCacheQueue = [[NSOperationQueue alloc] init];
  _invalidateCacheQueue.maxConcurrentOperationCount = 1;

  _expandedUrls = [[NSMutableSet alloc] initWithCapacity:40];

  return self;
}

- (void)dealloc {
  [_notificationCenter removeObserver:self];
}

- (void)setUp {
  [_notificationCenter addObserver:self selector:@selector(cacheInvalidated:) name:qInvalidatedCacheEvent object:nil];

  [self addViews];

  [self reload];
}

#pragma mark VRMovementsAndActionsProtocol
- (void)viMotionLeft:(id)sender event:(NSEvent *)event {
  [self fileOutlineViewDoubleClicked:sender];
}

- (void)viMotionUp:(id)sender event:(NSEvent *)event {
  [_fileOutlineView moveSelectionByDelta:-1];
}

- (void)viMotionDown:(id)sender event:(NSEvent *)event {
  [_fileOutlineView moveSelectionByDelta:1];
}

- (void)viMotionRight:(id)sender event:(NSEvent *)event {
  [self fileOutlineViewDoubleClicked:sender];
}

- (void)actionSpace:(id)sender event:(NSEvent *)event {
  [self fileOutlineViewDoubleClicked:sender];
}

- (void)actionCarriageReturn:(id)sender event:(NSEvent *)event {
  [self fileOutlineViewDoubleClicked:sender];
}

- (void)actionEscape:(id)sender event:(NSEvent *)event {
  [self.window makeFirstResponder:[self.window.windowController vimView].textView];
}

#pragma mark NSOutlineViewDataSource
- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(VRNode *)item {
  VRNode *currentNode = item ?: _rootNode;

  if (!currentNode.children) {
    [self buildChildNodesForNode:currentNode];
  }

  return currentNode.children.count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(VRNode *)item {
  if (!item) {
    return _rootNode.children[(NSUInteger) index];
  }

  return item.children[(NSUInteger) index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(VRNode *)item {
  return item.dir;
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn
           byItem:(VRNode *)item {

  return item.name;
}

#pragma mark NSOutlineViewDelegate
- (NSCell *)outlineView:(NSOutlineView *)outlineView dataCellForTableColumn:(NSTableColumn *)tableColumn item:(VRNode *)item {
  NSTextFieldCell *cell = [tableColumn dataCellForRow:[_fileOutlineView rowForItem:item]];
  cell.textColor = item.hidden ? [NSColor grayColor] : [NSColor textColor];
  cell.image = [_fileItemManager iconForUrl:item.url];

  return cell;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldExpandItem:(VRNode *)item {
  [_expandedUrls addObject:item.url];

  return YES;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldCollapseItem:(VRNode *)item {
  [_expandedUrls removeObject:item.url];

  return YES;
}

#pragma mark NSView

- (BOOL)mouseDownCanMoveWindow {
  // I dunno why, but if we don't override this, then the window title has the inactive appearance and the drag in the
  // VRWorkspaceView in combination with the vim view does not work correctly. Overriding -isOpaque does not suffice.
  return NO;
}

#pragma mark Private
- (void)addViews {
  NSTableColumn *tableColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
  tableColumn.dataCell = [[OakImageAndTextCell alloc] init];
  [tableColumn.dataCell setAllowsEditingTextAttributes:YES];
  [tableColumn.dataCell setLineBreakMode:NSLineBreakByTruncatingTail];

  _fileOutlineView = [[VROutlineView alloc] initWithFrame:CGRectZero];
  [_fileOutlineView addTableColumn:tableColumn];
  _fileOutlineView.outlineTableColumn = tableColumn;
  [_fileOutlineView sizeLastColumnToFit];
  _fileOutlineView.allowsEmptySelection = YES;
  _fileOutlineView.allowsMultipleSelection = NO;
  _fileOutlineView.headerView = nil;
  _fileOutlineView.focusRingType = NSFocusRingTypeNone;
  _fileOutlineView.dataSource = self;
  _fileOutlineView.delegate = self;
  _fileOutlineView.movementsAndActionDelegate = self;
  [_fileOutlineView setDoubleAction:@selector(fileOutlineViewDoubleClicked:)];

  NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  scrollView.translatesAutoresizingMaskIntoConstraints = NO;
  scrollView.hasVerticalScroller = YES;
  scrollView.hasHorizontalScroller = YES;
  scrollView.borderType = NSBezelBorder;
  scrollView.autohidesScrollers = YES;
  scrollView.documentView = _fileOutlineView;
  [self addSubview:scrollView];

  NSPopUpButton *settingsButton = [[NSPopUpButton alloc] initWithFrame:CGRectZero pullsDown:YES];
  settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
  settingsButton.bordered = NO;

  NSMenuItem *item = [NSMenuItem new];
  item.title = @"";
  item.image = [NSImage imageNamed:NSImageNameActionTemplate];
  [item.image setSize:NSMakeSize(12, 12)];

  [settingsButton.cell setBackgroundStyle:NSBackgroundStyleRaised];
  [settingsButton.cell setUsesItemFromMenu:NO];
  [settingsButton.cell setMenuItem:item];
  [settingsButton.menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
  [self addSubview:settingsButton];

  _showFoldersFirstMenuItem = [[NSMenuItem alloc] initWithTitle:@"Show Folders First"
                                                         action:@selector(toggleShowFoldersFirst:) keyEquivalent:@""];
  _showFoldersFirstMenuItem.target = self;
  _showFoldersFirstMenuItem.state = [_userDefaults boolForKey:qDefaultShowFoldersFirst] ? NSOnState : NSOffState;
  [settingsButton.menu addItem:_showFoldersFirstMenuItem];

  _showHiddenMenuItem = [[NSMenuItem alloc] initWithTitle:@"Show Hidden Files"
                                                   action:@selector(toggleShowHiddenFiles:) keyEquivalent:@""];
  _showHiddenMenuItem.target = self;
  _showHiddenMenuItem.state = [_userDefaults boolForKey:qDefaultShowHiddenInFileBrowser] ? NSOnState : NSOffState;
  [settingsButton.menu addItem:_showHiddenMenuItem];

  _syncWorkspaceWithPwdMenuItem = [[NSMenuItem alloc] initWithTitle:@"Sync Workspace with Vim's 'pwd'"
                                                             action:@selector(toggleSyncWorkspaceWithPwd:)
                                                      keyEquivalent:@""];
  _syncWorkspaceWithPwdMenuItem.target = self;
  _syncWorkspaceWithPwdMenuItem.state =
      [_userDefaults boolForKey:qDefaultSyncWorkingDirectoryWithVimPwd] ? NSOnState : NSOffState;
  [settingsButton.menu addItem:_syncWorkspaceWithPwdMenuItem];

  NSDictionary *views = @{
      @"outline" : scrollView,
      @"settings" : settingsButton,
  };

  CONSTRAIN(@"H:[settings]|");
  CONSTRAIN(@"H:|-(-1)-[outline(>=50)]-(-1)-|");
  CONSTRAIN(@"V:|-(-1)-[outline(>=50)][settings]-(3)-|");
}

- (IBAction)toggleSyncWorkspaceWithPwd:(id)sender {
  NSInteger oldState = _syncWorkspaceWithPwdMenuItem.state;
  _syncWorkspaceWithPwdMenuItem.state = !oldState;

  [self reload];
}

- (IBAction)toggleShowFoldersFirst:(id)sender {
  NSInteger oldState = _showFoldersFirstMenuItem.state;
  _showFoldersFirstMenuItem.state = !oldState;

  [self reload];
}

- (IBAction)toggleShowHiddenFiles:(id)sender {
  NSInteger oldState = _showHiddenMenuItem.state;
  _showHiddenMenuItem.state = !oldState;

  [self reload];
}

- (void)fileOutlineViewDoubleClicked:(id)sender {
  VRNode *item = [_fileOutlineView itemAtRow:_fileOutlineView.selectedRow];

  if (!item.dir) {
    VROpenMode mode = open_mode_from_event(
        [NSApp currentEvent],
        [_userDefaults stringForKey:qDefaultDefaultOpeningBehavior]
    );
    [(VRMainWindowController *) self.window.windowController openFileWithUrls:item.url openMode:mode];
    return;
  }

  if ([_fileOutlineView isItemExpanded:item]) {
    [_fileOutlineView collapseItem:item];
  } else {
    [_fileOutlineView expandItem:item];
  }
}

- (BOOL)showHiddenFiles {
  return _showHiddenMenuItem.state == NSOnState;
}

- (BOOL)showFoldersFirst {
  return _showFoldersFirstMenuItem.state == NSOnState;
}

- (void)cacheInvalidated:(NSNotification *)notification {
  [_invalidateCacheQueue addOperationWithBlock:^{
    // We wait here till all file item operations are finished, because, for instance, the children items of the root
    // can be deleted by -reload and Open Quickly file item operations are trying to use them.
    [_fileItemManager waitTillFileItemOperationsFinished];
    DDLogDebug(@"finished wating till file item operations are done");

    dispatch_to_main_thread(^{
      @synchronized (_fileItemManager) {
        [self reload];
      }
    });
  }];
}

- (void)reload {
  NSURL *selectedUrl = [[_fileOutlineView itemAtRow:_fileOutlineView.selectedRow] url];
  CGRect visibleRect = _fileOutlineView.enclosingScrollView.contentView.visibleRect;

  [self reCacheNodes];
  [_fileOutlineView reloadData];
  [self restoreExpandedStates];

  [_fileOutlineView scrollRectToVisible:visibleRect];

  [self selectNodeWithUrl:selectedUrl];
}

- (void)selectNodeWithUrl:(NSURL *)selectedUrl {
  if (selectedUrl == nil) {
    return;
  }

  for (NSUInteger i = 0; i < _fileOutlineView.numberOfRows; i++) {
    if ([[[_fileOutlineView itemAtRow:i] url] isEqualTo:selectedUrl]) {
      [_fileOutlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
      return;
    }
  }
}

- (void)restoreExpandedStates {
  NSSet *oldExpandedStates = _expandedUrls.copy;
  [_expandedUrls removeAllObjects];

  [self restoreExpandState:_rootNode.children states:oldExpandedStates];
}

- (void)reCacheNodes {
  _rootNode = [[VRNode alloc] init];
  _rootNode.item = [_fileItemManager itemForUrl:_rootUrl];

  [self buildChildNodesForNode:_rootNode];
  DDLogDebug(@"Re-cached root node");
}

- (void)restoreExpandState:(NSArray *)children states:(NSSet *)states {
  for (VRNode *node in children) {
    if (node.dir && [states containsObject:node.url]) {
      [_fileOutlineView expandItem:node];

      if (!node.children.isEmpty) {
        [self restoreExpandState:node.children states:states];
      }
    }
  }
}

- (void)buildChildNodesForNode:(VRNode *)parentNode {
  NSArray *childItems = [_fileItemManager childrenOfItem:parentNode.item];
  NSMutableArray *children = [[NSMutableArray alloc] initWithCapacity:childItems.count];
  for (id item in childItems) {
    VRNode *node = [self nodeFromItem:item];
    [children addObject:node];
  }

  NSArray *filteredChildren = [self filterHiddenNodesIfNec:children];
  if ([self showFoldersFirst]) {
    NSSortDescriptor *folderDescriptor = [[NSSortDescriptor alloc] initWithKey:@"dir" ascending:YES
                                                                    comparator:qNodeDirComparator];

    parentNode.children = [filteredChildren sortedArrayUsingDescriptors:@[folderDescriptor]];
  } else {
    parentNode.children = filteredChildren;
  }
}

- (VRNode *)nodeFromItem:(id)item {
  VRNode *node = [[VRNode alloc] init];
  node.url = [_fileItemManager urlForItem:item];
  node.dir = [_fileItemManager isItemDir:item];
  node.hidden = [_fileItemManager isItemHidden:item];
  node.name = [_fileItemManager nameOfItem:item];
  node.item = item;
  node.children = nil;

  return node;
}

- (NSArray *)filterHiddenNodesIfNec:(NSArray *)nodes {
  if ([self showHiddenFiles]) {
    return nodes;
  }

  NSMutableArray *result = [[NSMutableArray alloc] initWithCapacity:nodes.count];
  for (VRNode *item in nodes) {
    if (!item.hidden) {
      [result addObject:item];
    }
  }

  return result;
}

@end