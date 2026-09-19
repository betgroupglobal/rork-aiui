//
//  PeopleStore.swift
//  SparkAI
//
//  Roster of people imported from CSV (or typed manually) whose details can
//  be dropped into sign-up form fields. The CSV template is shareable so
//  users can fill a spreadsheet offline and import it in one tap. All data
//  stays on-device (PersistenceStore, Application Support).
//

import Foundation
import Observation

/// One person on the roster. Every field is optional — a row just needs a
/// name or an email to be useful.
nonisolated struct Person: Codable, Identifiable, Equatable {
    var id: UUID
    var firstName: String
    var lastName: String
    var email: String
    var phone: String
    var company: String
    var username: String
    var website: String

    init(
        id: UUID = UUID(),
        firstName: String = "",
        lastName: String = "",
        email: String = "",
        phone: String = "",
        company: String = "",
        username: String = "",
        website: String = ""
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
        self.company = company
        self.username = username
        self.website = website
    }

    var displayName: String {
        let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? (email.isEmpty ? "Unnamed" : email) : name
    }

    /// Every lowercase key a form might use for each detail, so the standard
    /// identifier matcher lands values without per-form configuration.
    var formValues: [String: String] {
        var values: [String: String] = [:]
        func set(_ keys: [String], _ value: String) {
            guard !value.isEmpty else { return }
            for key in keys { values[key] = value }
        }
        let fullName = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        set(["first_name", "firstname", "fname", "given_name", "givenname"], firstName)
        set(["last_name", "lastname", "lname", "surname", "family_name", "familyname"], lastName)
        set(["name", "full_name"], fullName)
        set(["email", "email_address", "emailaddress", "mail"], email)
        set(["phone", "phone_number", "phonenumber", "telephone", "tel", "mobile", "cell"], phone)
        set(["company", "company_name", "companyname", "organization", "organisation", "org"], company)
        set(["username", "user_name", "username1", "nickname", "handle", "login"], username)
        set(["website", "url", "site", "homepage", "web"], website)
        return values
    }
}

/// RFC-4180-ish CSV reader: quoted fields, embedded commas/newlines and
/// doubled quotes are all handled.
nonisolated enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
        let chars = Array(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0

        while index < chars.count {
            let char = chars[index]
            if inQuotes {
                if char == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(char)
                }
                index += 1
            } else if char == "\"" {
                inQuotes = true
                index += 1
            } else if char == "," {
                row.append(field)
                field = ""
                index += 1
            } else if char == "\n" {
                row.append(field)
                field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
                index += 1
            } else if char == "\r" {
                index += 1
            } else {
                field.append(char)
                index += 1
            }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}

@MainActor
@Observable
final class PeopleStore {
    static let shared = PeopleStore()
    static let templateCSV = """
    first_name,last_name,email,phone,company,username,website
    Ada,Lovelace,ada@example.com,+1 555 010 2030,Analytical Engines,ada,https://example.com
    Alan,Turing,alan@example.com,+1 555 010 4050,Bletchley Labs,turing,https://example.org
    """

    private(set) var people: [Person] = []
    private static let storeKey = "people-roster"
    private static let cap = 100

    private init() {
        people = PersistenceStore.load([Person].self, forKey: Self.storeKey) ?? []
    }

    func add(_ person: Person) {
        people.insert(person, at: 0)
        persist()
    }

    func remove(_ id: UUID) {
        people.removeAll { $0.id == id }
        persist()
    }

    /// Finds a person by exact email, exact name, then substring — used by
    /// the agent's `signup_form` "person" argument.
    func match(_ query: String) -> Person? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        return people.first { $0.email.lowercased() == q }
            ?? people.first { $0.displayName.lowercased() == q }
            ?? people.first { $0.email.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
    }

    /// Imports CSV text (header row required). Returns how many new people
    /// were added; duplicates (same email) are skipped.
    @discardableResult
    func importCSV(_ text: String) -> Int {
        let rows = CSVParser.parse(text)
        guard let header = rows.first else { return 0 }
        let columns = Self.columns(for: header)
        guard columns.contains(where: { $0 != nil }) else { return 0 }

        var added = 0
        for row in rows.dropFirst() {
            var person = Person()
            for (index, column) in columns.enumerated() where index < row.count {
                let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                switch column {
                case .firstName: person.firstName = value
                case .lastName: person.lastName = value
                case .email: person.email = value
                case .phone: person.phone = value
                case .company: person.company = value
                case .username: person.username = value
                case .website: person.website = value
                case nil: break
                }
            }
            guard !person.email.isEmpty || !person.firstName.isEmpty || !person.lastName.isEmpty else { continue }
            if !person.email.isEmpty, people.contains(where: { $0.email.caseInsensitiveCompare(person.email) == .orderedSame }) {
                continue
            }
            people.append(person)
            added += 1
        }
        people = Array(people.prefix(Self.cap))
        persist()
        return added
    }

    // MARK: - Header mapping

    private enum PersonColumn {
        case firstName, lastName, email, phone, company, username, website
    }

    /// Maps normalized header names to person fields; unrecognized columns
    /// are kept as nil placeholders so row indices still line up.
    private static func columns(for header: [String]) -> [PersonColumn?] {
        let map: [(PersonColumn, Set<String>)] = [
            (.firstName, ["firstname", "first", "fname", "givenname", "givenname2", "given"]),
            (.lastName, ["lastname", "last", "lname", "surname", "familyname", "family"]),
            (.email, ["email", "emailaddress", "mail", "email1", "primaryemail"]),
            (.phone, ["phone", "phonenumber", "telephone", "tel", "mobile", "cell", "phonenumer"]),
            (.company, ["company", "companyname", "organization", "organisation", "org", "employer"]),
            (.username, ["username", "user", "nickname", "handle", "login", "screenname"]),
            (.website, ["website", "url", "site", "homepage", "web", "domain"])
        ]
        return header.map { raw in
            let normalized = raw.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            let key = String(String.UnicodeScalarView(normalized))
            return map.first { $0.1.contains(key) }?.0
        }
    }

    private func persist() {
        PersistenceStore.save(people, forKey: Self.storeKey)
    }
}
