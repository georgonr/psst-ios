//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

@MainActor
struct UserDiscoveryServiceTest {
    private var service: UserDiscoveryService
    private var clientProxy: ClientProxyMock
    
    private var searchResults: [UserProfile] {
        [.mockAlice, .mockBob, .mockCharlie]
    }
    
    init() {
        clientProxy = .init(.init(userID: "@foo:matrix.org"))
        service = UserDiscoveryService(clientProxy: clientProxy)
    }
    
    @Test
    func queryShowingResults() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [UserProfile.mockAlice], limited: true))
        
        let results = await (try? search(query: "A A").get()) ?? []
        assertSearchResults(results, toBe: 1)
    }
    
    @Test
    func ownerIsFiltered() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [UserProfile(userID: "@foo:matrix.org")], limited: true))
        
        let results = await (try? search(query: "A A").get()) ?? []
        assertSearchResults(results, toBe: 0)
    }
    
    @Test
    func getProfileIsNotCalled() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .success(.init(userID: "@alice:matrix.org"))
        
        // PSST (D88): a query that is not an account name (contains a space) never triggers a profile lookup
        let results = await (try? search(query: "A A").get()) ?? []
        assertSearchResults(results, toBe: 3)
        #expect(!clientProxy.profileForCalled)
    }
    
    @Test
    func getProfileIsNotCalledForAccountOwnerID() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .success(.init(userID: "@alice:matrix.org"))
        
        let results = await (try? search(query: "foo:matrix.org").get()) ?? []
        assertSearchResults(results, toBe: 3)
        #expect(!clientProxy.profileForCalled)
    }
    
    @Test
    func localResultShows() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .success(.init(userID: "@some:matrix.org"))
        
        let results = await (try? search(query: "@a:b.com").get()) ?? []
        
        assertSearchResults(results, toBe: 4)
        #expect(clientProxy.profileForCalled)
    }
    
    @Test
    func localResultShowsOnSearchError() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        clientProxy.profileForReturnValue = .success(.init(userID: "@some:matrix.org"))
        
        let results = await (try? search(query: "@a:b.com").get()) ?? []
        
        assertSearchResults(results, toBe: 1)
        #expect(clientProxy.profileForCalled)
    }
    
    @Test
    func searchErrorTriggers() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        clientProxy.profileForReturnValue = .success(.init(userID: "@some:matrix.org"))
        
        switch await search(query: "some query") {
        case .success:
            Issue.record("Search users must fail")
        case .failure(let error):
            #expect(error == UserDiscoveryErrorType.failedSearchingUsers)
        }
        
        #expect(!clientProxy.profileForCalled)
    }
    
    @Test
    func localResultWithDuplicates() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .success(.init(userID: "@bob:matrix.org"))
        
        let results = await (try? search(query: "@a:b.com").get()) ?? []
        
        assertSearchResults(results, toBe: 3)
        let firstUserID = results.first?.id
        #expect(firstUserID == "@bob:matrix.org")
        #expect(clientProxy.profileForCalled)
    }
    
    @Test
    func searchResultsShowWhenGetProfileFails() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        
        let results = await (try? search(query: "@a:b.com").get()) ?? []
        
        let firstUserID = results.first?.id
        #expect(firstUserID == "@a:b.com")
        #expect(clientProxy.profileForCalled)
    }
    
    @Test
    func psstBareAccountNameLooksUpExactUser() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [], limited: false))
        clientProxy.profileForReturnValue = .success(.init(userID: "@jana:matrix.org", displayName: "Jana"))
        
        let results = await (try? search(query: "Jana").get()) ?? []
        
        assertSearchResults(results, toBe: 1)
        #expect(clientProxy.profileForReceivedUserID == "@jana:matrix.org")
    }
    
    @Test
    func psstBareAccountNameWithoutProfileShowsNothing() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [], limited: false))
        clientProxy.profileForReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        
        let results = await (try? search(query: "@nobody").get()) ?? []
        
        assertSearchResults(results, toBe: 0)
        #expect(clientProxy.profileForReceivedUserID == "@nobody:matrix.org")
    }
    
    // MARK: - Private
    
    private func assertSearchResults(_ results: [UserProfile], toBe count: Int) {
        #expect(count >= 0)
        #expect(results.count == count)
        #expect(results.isEmpty == (count == 0))
    }
    
    private func search(query: String) async -> Result<[UserProfile], UserDiscoveryErrorType> {
        await service.searchProfiles(with: query)
    }
}
