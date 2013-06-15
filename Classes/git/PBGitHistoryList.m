//
//  PBGitHistoryList.m
//  GitX
//
//  Created by Nathan Kinsinger on 2/20/10.
//  Copyright 2010 Nathan Kinsinger. All rights reserved.
//

#import "PBGitHistoryList.h"
#import "PBGitRepository.h"
#import "PBGitRevList.h"
#import "PBGitGrapher.h"
#import "PBGitHistoryGrapher.h"
#import "PBGitSHA.h"



@interface PBGitHistoryList ()

@property (nonatomic, assign) BOOL isUpdating;
@property (nonatomic, strong) NSMutableArray *commits;
@property (nonatomic, weak) PBGitRepository *repository;

- (void) resetGraphing;

- (PBGitHistoryGrapher *) grapher;
- (NSInvocationOperation *) operationForCommits:(NSArray *)newCommits;

- (void) updateProjectHistoryForRev:(PBGitRevSpecifier *)rev;
- (void) updateHistoryForRev:(PBGitRevSpecifier *)rev;

@end




@implementation PBGitHistoryList


#pragma mark -
#pragma mark Public

- (id) initWithRepository:(PBGitRepository *)repo
{
    self = [super init];
    if (!self)
        return nil;
    
	self.commits = [NSMutableArray array];
	self.repository = repo;
	lastBranchFilter = -1;
	[self.repository addObserver:self forKeyPath:@"currentBranch" options:0 context:@"currentBranch"];
	[self.repository addObserver:self forKeyPath:@"currentBranchFilter" options:0 context:@"currentBranch"];
	[self.repository addObserver:self forKeyPath:@"hasChanged" options:0 context:@"repositoryHasChanged"];

	shouldReloadProjectHistory = YES;
	self.projectRevList = [[PBGitRevList alloc] initWithRepository:self.repository rev:[PBGitRevSpecifier allBranchesRevSpec] shouldGraph:NO];

	return self;
}

- (void)dealloc {
    [self cleanup];
}

- (void) forceUpdate
{
	if ([self.repository.currentBranch isSimpleRef])
		shouldReloadProjectHistory = YES;

	[self updateHistory];
}


- (void) updateHistory
{
	PBGitRevSpecifier *rev = self.repository.currentBranch;
	if (!rev)
		return;

	if ([rev isSimpleRef])
		[self updateProjectHistoryForRev:rev];
	else
		[self updateHistoryForRev:rev];
}


- (void)cleanup
{
	if (currentRevList) {
		[currentRevList removeObserver:self forKeyPath:@"commits"];
		[currentRevList cancel];
	}
	[graphQueue cancelAllOperations];

	[self.repository removeObserver:self forKeyPath:@"currentBranch"];
	[self.repository removeObserver:self forKeyPath:@"currentBranchFilter"];
	[self.repository removeObserver:self forKeyPath:@"hasChanged"];
}


- (NSArray *) projectCommits
{
	return [self.projectRevList.commits copy];
}



#pragma mark -
#pragma mark History Grapher delegate methods

- (void) addCommitsFromArray:(NSArray *)array
{
	if (!array || [array count] == 0)
		return;

	if (resetCommits) {
		self.commits = [NSMutableArray array];
		resetCommits = NO;
	}

	NSRange range = NSMakeRange([self.commits count], [array count]);
	NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:range];

	[self willChange:NSKeyValueChangeInsertion valuesAtIndexes:indexes forKey:@"commits"];
	[self.commits addObjectsFromArray:array];
	[self didChange:NSKeyValueChangeInsertion valuesAtIndexes:indexes forKey:@"commits"];
}


- (void) updateCommitsFromGrapher:(NSDictionary *)commitData
{
	if ([commitData objectForKey:kCurrentQueueKey] != graphQueue)
		return;

	[self addCommitsFromArray:[commitData objectForKey:kNewCommitsKey]];
}

- (void) finishedGraphing
{
	if (!currentRevList.isParsing && ([[graphQueue operations] count] == 0)) {
		self.isUpdating = NO;
	}
}



#pragma mark -
#pragma mark Private

- (void) resetGraphing
{
	resetCommits = YES;
	self.isUpdating = YES;

	[graphQueue cancelAllOperations];
	graphQueue = [[NSOperationQueue alloc] init];
	[graphQueue setMaxConcurrentOperationCount:1];

	grapher = [self grapher];
}


- (NSInvocationOperation *) operationForCommits:(NSArray *)newCommits
{
	return [[NSInvocationOperation alloc] initWithTarget:grapher selector:@selector(graphCommits:) object:newCommits];
}


- (NSSet *) baseCommitsForLocalRefs
{
	NSMutableSet *baseCommitSHAs = [NSMutableSet set];
	NSDictionary *refs = self.repository.refs;

	for (PBGitSHA *sha in refs)
		for (PBGitRef *ref in [refs objectForKey:sha])
			if ([ref isBranch] || [ref isTag])
				[baseCommitSHAs addObject:sha];

	if (![[PBGitRef refFromString:[[self.repository headRef] simpleRef]] type])
		[baseCommitSHAs addObject:[self.repository headSHA]];

	return baseCommitSHAs;
}


- (NSSet *) baseCommitsForRemoteRefs
{
	NSMutableSet *baseCommitSHAs = [NSMutableSet set];
	NSDictionary *refs = self.repository.refs;

	PBGitRef *remoteRef = [[self.repository.currentBranch ref] remoteRef];

	for (PBGitSHA *sha in refs)
		for (PBGitRef *ref in [refs objectForKey:sha])
			if ([remoteRef isEqualToRef:[ref remoteRef]])
				[baseCommitSHAs addObject:sha];

	return baseCommitSHAs;
}


- (NSSet *) baseCommits
{
	if ((self.repository.currentBranchFilter == kGitXSelectedBranchFilter) || (self.repository.currentBranchFilter == kGitXAllBranchesFilter)) {
		if (lastSHA)
			return [NSMutableSet setWithObject:lastSHA];
		else if ([self.repository.currentBranch isSimpleRef]) {
			PBGitRef *currentRef = [self.repository.currentBranch ref];
			PBGitSHA *sha = [self.repository shaForRef:currentRef];
			if (sha)
				return [NSMutableSet setWithObject:sha];
		}
	}
	else if (self.repository.currentBranchFilter == kGitXLocalRemoteBranchesFilter) {
		if ([[self.repository.currentBranch ref] isRemote])
			return [self baseCommitsForRemoteRefs];
		else
			return [self baseCommitsForLocalRefs];
	}

	return [NSMutableSet set];
}


- (PBGitHistoryGrapher *) grapher
{
	BOOL viewAllBranches = (self.repository.currentBranchFilter == kGitXAllBranchesFilter);

	return [[PBGitHistoryGrapher alloc] initWithBaseCommits:[self baseCommits] viewAllBranches:viewAllBranches queue:graphQueue delegate:self];
}


- (void) setCurrentRevList:(PBGitRevList *)parser
{
	if (currentRevList == parser)
		return;

	if (currentRevList)
		[currentRevList removeObserver:self forKeyPath:@"commits"];

	currentRevList = parser;

	[currentRevList addObserver:self forKeyPath:@"commits" options:NSKeyValueObservingOptionNew context:@"commitsUpdated"];
}


- (BOOL) isAllBranchesOnlyUpdate
{
	return (lastBranchFilter == kGitXAllBranchesFilter) && (self.repository.currentBranchFilter == kGitXAllBranchesFilter);
}


- (BOOL) isLocalRemoteOnlyUpdate:(PBGitRevSpecifier *)rev
{
	if ((lastBranchFilter == kGitXLocalRemoteBranchesFilter) && (self.repository.currentBranchFilter == kGitXLocalRemoteBranchesFilter)) {
		if (!lastRemoteRef && ![[rev ref] isRemote])
			return YES;

		if ([lastRemoteRef isEqualToRef:[[rev ref] remoteRef]])
			return YES;
	}

	return NO;
}


- (BOOL) selectedBranchNeedsNewGraph:(PBGitRevSpecifier *)rev
{
	if (![rev isSimpleRef])
		return YES;

	if ([self isAllBranchesOnlyUpdate] || [self isLocalRemoteOnlyUpdate:rev]) {
		lastRemoteRef = [[rev ref] remoteRef];
		lastSHA = nil;
		self.isUpdating = NO;
		return NO;
	}

	PBGitSHA *revSHA = [self.repository shaForRef:[rev ref]];
	if ([revSHA isEqual:lastSHA] && (lastBranchFilter == self.repository.currentBranchFilter))
		return NO;

	lastBranchFilter = self.repository.currentBranchFilter;
	lastRemoteRef = [[rev ref] remoteRef];
	lastSHA = revSHA;

	return YES;
}


- (BOOL) haveRefsBeenModified
{
	[self.repository reloadRefs];

	NSMutableSet *currentRefSHAs = [NSMutableSet setWithArray:[self.repository.refs allKeys]];
	[currentRefSHAs minusSet:lastRefSHAs];
	lastRefSHAs = [NSSet setWithArray:[self.repository.refs allKeys]];

	return [currentRefSHAs count] != 0;
}


#pragma mark updating history

- (void) updateProjectHistoryForRev:(PBGitRevSpecifier *)rev
{
	[self setCurrentRevList:self.projectRevList];

	if ([self haveRefsBeenModified])
		shouldReloadProjectHistory = YES;

	if (![self selectedBranchNeedsNewGraph:rev] && !shouldReloadProjectHistory)
		return;

	[self resetGraphing];

	if (shouldReloadProjectHistory) {
		shouldReloadProjectHistory = NO;
		lastBranchFilter = -1;
		lastRemoteRef = nil;
		lastSHA = nil;
		self.commits = [NSMutableArray array];
		[self.projectRevList loadRevisons];
		return;
	}

	[graphQueue addOperation:[self operationForCommits:self.projectRevList.commits]];
}


- (void) updateHistoryForRev:(PBGitRevSpecifier *)rev
{
	PBGitRevList *otherRevListParser = [[PBGitRevList alloc] initWithRepository:self.repository rev:rev shouldGraph:YES];

	[self setCurrentRevList:otherRevListParser];
	[self resetGraphing];
	lastBranchFilter = -1;
	lastRemoteRef = nil;
	lastSHA = nil;
	self.commits = [NSMutableArray array];

	[otherRevListParser loadRevisons];
}



#pragma mark -
#pragma mark Key Value Observing

- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if ([@"currentBranch" isEqualToString:(__bridge NSString*)context]) {
		[self updateHistory];
		return;
	}

	if ([@"repositoryHasChanged" isEqualToString:(__bridge NSString*)context]) {
		[self forceUpdate];
		return;
	}

	if ([@"commitsUpdated" isEqualToString:(__bridge NSString*)context]) {
		NSInteger changeKind = [(NSNumber *)[change objectForKey:NSKeyValueChangeKindKey] intValue];
		if (changeKind == NSKeyValueChangeInsertion) {
			NSArray *newCommits = [change objectForKey:NSKeyValueChangeNewKey];
			if ([self.repository.currentBranch isSimpleRef])
				[graphQueue addOperation:[self operationForCommits:newCommits]];
			else
				[self addCommitsFromArray:newCommits];
		}
		return;
	}

	[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

@end
