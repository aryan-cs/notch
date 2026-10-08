//
//  CalendarAccounts.swift
//  boringNotch
//

import EventKit
import Foundation

// MARK: - Account groups

/// The calendars of one account (an `EKSource`, e.g. a Google account added in
/// System Settings → Internet Accounts), as the settings list shows them.
struct CalendarAccountGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let isGoogleAccount: Bool
    let calendars: [CalendarModel]

    /// Local, subscribed and birthday calendars, which share one "Other" group.
    var isOther: Bool { id == CalendarModel.otherAccountID }

    /// Groups calendars by account. Accounts sort by title with "Other" last. Within
    /// an account the calendar named after it (a Google account's primary calendar)
    /// leads, then the rest by title.
    static func grouped(_ calendars: [CalendarModel]) -> [CalendarAccountGroup] {
        let byAccount = Dictionary(grouping: calendars, by: \.accountID)
        let groups = byAccount.map { accountID, calendars in
            let account = calendars[0].account
            return CalendarAccountGroup(
                id: accountID,
                title: account,
                isGoogleAccount: calendars.contains(where: \.isGoogleAccount),
                calendars: calendars.sorted { lhs, rhs in
                    let lhsIsPrimary = lhs.title.caseInsensitiveCompare(account) == .orderedSame
                    let rhsIsPrimary = rhs.title.caseInsensitiveCompare(account) == .orderedSame
                    if lhsIsPrimary != rhsIsPrimary { return lhsIsPrimary }
                    let order = lhs.title.localizedStandardCompare(rhs.title)
                    return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
                }
            )
        }
        return groups.sorted { lhs, rhs in
            if lhs.isOther != rhs.isOther { return rhs.isOther }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}

// MARK: - Google accounts

extension CalendarModel {
    /// `accountID` shared by local, subscribed and birthday calendars.
    static let otherAccountID = "other"

    /// EventKit doesn't say which service a CalDAV account talks to, so Google is
    /// recognised by name: Internet Accounts titles a Google account with its address
    /// (Gmail or Workspace) unless the user renames it.
    static func isLikelyGoogleAccount(sourceType: EKSourceType, title: String) -> Bool {
        guard sourceType == .calDAV else { return false }
        let lowercased = title.lowercased()
        return lowercased.contains("google") || lowercased.contains("gmail") || title.isLikelyEmailAddress
    }
}

extension String {
    /// Loose `name@domain.tld` shape check, enough to tell an account titled with its
    /// address from one the user renamed (e.g. "Work").
    var isLikelyEmailAddress: Bool {
        let parts = split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !contains(where: \.isWhitespace) else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}

// MARK: - Selection

extension CalendarSelectionState {
    /// Whether the calendar with this identifier is shown in the notch.
    func includes(_ calendarID: String) -> Bool {
        switch self {
        case .all:
            return true
        case .selected(let identifiers):
            return identifiers.contains(calendarID)
        case .excluded(let identifiers):
            return !identifiers.contains(calendarID)
        }
    }

    /// The state with `calendarIDs` shown or hidden. Hiding everything is allowed and
    /// shows no events. Identifiers of calendars that no longer exist are kept: they
    /// hide nothing, and dropping them while an account is briefly unavailable would
    /// lose the user's choices.
    func setting(
        _ calendarIDs: some Sequence<String>, selected: Bool, knownCalendarIDs: Set<String>
    ) -> CalendarSelectionState {
        var excluded: Set<String>
        switch migrated(knownCalendarIDs: knownCalendarIDs) {
        case .all:
            excluded = []
        case .excluded(let identifiers):
            excluded = identifiers
        case .selected(var identifiers):
            // Only reachable while no calendars are known; edit the allow-list as-is.
            if selected {
                identifiers.formUnion(calendarIDs)
            } else {
                identifiers.subtract(calendarIDs)
            }
            return .selected(identifiers)
        }

        if selected {
            excluded.subtract(calendarIDs)
        } else {
            excluded.formUnion(calendarIDs)
        }
        return excluded.isEmpty ? .all : .excluded(excluded)
    }

    /// Converts a legacy allow-list into an exclusion list against the calendars that
    /// exist now, so calendars added later are shown. If none of the allowed calendars
    /// still exist (e.g. the account was removed and re-added, which issues new
    /// identifiers), everything is shown rather than nothing. Without known calendars
    /// (no access yet) the state is left alone.
    func migrated(knownCalendarIDs: Set<String>) -> CalendarSelectionState {
        guard case .selected(let identifiers) = self, !knownCalendarIDs.isEmpty else { return self }
        guard !identifiers.isDisjoint(with: knownCalendarIDs) else { return .all }
        let excluded = knownCalendarIDs.subtracting(identifiers)
        return excluded.isEmpty ? .all : .excluded(excluded)
    }
}
