//
//  Stencil.swift
//
//  Created by John Biggs on 04.01.24.
//

import Foundation
import Yams // For decoding a yaml header, if it exists
import System
import Stencil
import Markdown
import SwiftGit2
import LHCInternal

public protocol CustomStencilSubscriptable {
    subscript(_ key: String) -> String? { get }
}

/// Load a template from the repository.
///
/// If a template ends with an extension like `.base.md`, `.base.html`, etc., then this loader will first look in the
/// project's embedded resources for the given base template file before trying to load it from the repository.
public class TemplateLoader: Loader, CustomStringConvertible {
    public let urls: [URL]

    public init(urls: [URL]) {
        self.urls = urls
    }

    public var description: String {
        "TemplateLoader(\(urls.map { $0.absoluteString }))"
    }

    public func loadTemplate(name: String, environment: Environment) throws -> Template {
        let value = try loadTemplates(nameOrRoot: name, environment: environment).first!
        return value.value!.0
    }

    private func recursivelyLoadContents(_ url: URL, subpath: String?, into contents: inout [String: String?]) throws {
        let fullURL = subpath == nil ? url : url.appending(path: subpath!)
        let directoryContents = try Internal.fileManager.contentsOfDirectory(
            at: fullURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .producesRelativePathURLs
        )

        for subsubURL in directoryContents {
            let absoluteURL = subsubURL.absoluteURL
            if (try? subsubURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                try recursivelyLoadContents(fullURL, subpath: subsubURL.path(percentEncoded: false), into: &contents)
            } else if subsubURL.pathExtensions.contains("template"),
                      let templateContents = Internal.fileManager.contents(atPath: absoluteURL.path(percentEncoded: false)) {
                let string = String(data: templateContents, encoding: .utf8)
                contents[fullURL.appending(component: subsubURL.path(percentEncoded: false)).path(percentEncoded: false)] = string
            } else {
                // Not a template or a directory, but still a file.
                contents[fullURL.appending(component: subsubURL.path(percentEncoded: false)).path(percentEncoded: false)] = .some(nil)
            }
        }
    }

    /// Loads one or more templates with the given template file or directory name.
    ///
    /// Returns a dictionary of subpaths in the repository. Each subpath key corresponds either to a template file, or a
    /// template directory's contents.
    ///
    /// In the former case, the associated value is a template object. If the template filename's last extension is
    /// "md", then the document will first be parsed for a YAML header, which will be parsed and removed from the
    /// original document before it is used to initialize the Template object. The parsed headers will be included
    /// as part of the return value.
    ///
    /// If the subpath key corresponds to a file that is not a template, but was present in a template directory, the
    /// associated value is nil.
    public func loadTemplates(
        nameOrRoot: String,
        environment: Environment
    ) throws -> [String: (Template, headers: [String: Any]?)?] {
        let fileURL = URL(filePath: nameOrRoot)

        var url: URL?
        if fileURL.pathExtensions.contains("base") {
            // This implementation is a bit weird because we can't rely on Bundle.module (it only gets generated if we're
            // built with SPM) and we have to use the real, non-stubbed FileManager so we can get the resource's contents
            // without conflicting with any test runs.
            let bundle = Bundle(for: LHCBundle.self)
            let paths = bundle.paths(forResourcesOfType: nil, inDirectory: nil)

            for path in paths {
                guard let resourceBundle = Bundle(path: path),
                      let resourcePath = resourceBundle.path(
                          forResource: fileURL.deletingPathExtension().path(percentEncoded: false),
                          ofType: fileURL.pathExtension
                      ) else {
                    continue
                }

                url = URL(filePath: resourcePath)
                break
            }
        }

        var isDirectory: Bool? = false
        if url == nil {
            // This absoluteURL nonsense is useful for calculating the relative paths in the content dictionaries
            // further down, modify or remove them at your own peril.
            for templateDirectoryURL in self.urls {
                let templateURL = URL(filePath: nameOrRoot, relativeTo: templateDirectoryURL)
                let templateAbsolutePath = templateURL.absoluteURL.path(percentEncoded: false)
                if Internal.fileManager.fileExists(atPath: templateAbsolutePath, isDirectory: &isDirectory) {
                    url = templateURL
                    break
                }
            }
        }

        guard let url else {
            throw TemplateDoesNotExist(templateNames: [nameOrRoot], loader: self)
        }

        var templateContents: [String: String?] = [:]
        if isDirectory == true {
            try recursivelyLoadContents(url, subpath: nil, into: &templateContents)
        } else {
            guard let data = Internal.fileManager.contents(atPath: url.absoluteURL.path(percentEncoded: false)),
                  let contents = String(data: data, encoding: .utf8) else {
                throw TemplateDoesNotExist(templateNames: [nameOrRoot], loader: self)
            }

            templateContents[nameOrRoot] = contents
        }

        return templateContents.reduce(into: [:]) {
            var (key, contents) = $1
            guard let url = URL(string: key), let contents else {
                // Still tell the caller where non-template files are, so it knows to copy them over.
                $0[key] = .some(nil)
                return
            }

            let delimiter = "---\n"
            let body: String
            let headers: CodingDictionary?

            // Find the boundaries of the YAML header, if one exists
            if url.pathExtension == "md",
               contents.starts(with: delimiter),
               let match = contents[delimiter.endIndex...].range(of: delimiter) {
                let decoder = YAMLDecoder()
                body = String(contents[match.upperBound...])
                let headersString = contents[match]
                headers = try? decoder.decode(CodingDictionary.self, from: headersString.data(using: .utf8)!)
            } else {
                body = contents
                headers = nil
            }

            let template = environment.templateClass.init(
                templateString: body,
                environment: environment,
                name: url.pathComponents.last!
            )

            if let templateExtension = key.ranges(of: ".template").last {
                key.removeSubrange(templateExtension)
            }

            $0[key] = (template, headers?.rawValue)
        }
    }
}

public class TemplateExtension: Stencil.Extension {
    func `get`(_ value: Any?, _ arguments: [Any]) throws -> Any? {
        guard arguments.count == 1, let key = arguments.first else {
            throw TemplateSyntaxError("""
                'get' requires one argument, which must be a key in a dictionary.
                """
            )
        }

        guard let value else { return nil }

        switch (key, value) {
        case let (key, value) as (String, [String: Any]):
            return value[key]
        case let (key, value) as (String, CustomStencilSubscriptable):
            return value[key]
        case let (key, value) as (String, [CustomStencilSubscriptable]):
            for item in value where item[key] != nil {
                return item // Yes, the item, not the value itself.
            }
            return nil
        case let (key, value) as (String, Any):
            let mirror = Mirror(reflecting: value)
            guard let property = mirror.children.first(where: { $0.label == key }) else {
                return nil
            }
            return property.value
        default:
            throw TemplateSyntaxError("""
                Don't know how to index into a \(type(of: value)) with a \(type(of: key)).
                """
            )
        }
    }

    func contains(_ value: Any?, _ arguments: [Any]) throws -> Any? {
        guard arguments.count == 1, let key = arguments.first else {
            throw TemplateSyntaxError("""
                'contains' requires one argument, which must be either a key in a dictionary or \
                an element in an array.
                """
            )
        }

        guard let value else { return false }

        switch (key, value) {
        case let (key, value) as (String, [String]):
            return value.contains(key)
        case let (key, value) as (String, [String: Any]):
            return value[key] != nil
        case let (key, value) as (String, CustomStencilSubscriptable):
            return value[key] != nil
        case let (key, value) as (String, [CustomStencilSubscriptable]):
            return value.contains { $0[key] != nil }
        default:
            throw TemplateSyntaxError("""
                Don't know how to index into a \(type(of: value)) with a \(type(of: key)).
                """
            )
        }
    }

    func attrs(_ value: Any?, _ arguments: [Any], context: Context) throws -> Any? {
        guard let attrsRef = train?.attrsRef else { return nil }

        let note: Note?
        switch value {
        case let tag as TagReferenceish:
            guard let oid = tag.tagOid else { return nil }
            note = try? repository.note(for: oid, notesRef: attrsRef)
        case let tag as Tagish:
            note = try? repository.note(for: tag.oid, notesRef: attrsRef)
        case let commit as Commitish:
            note = try? repository.note(for: commit.oid, notesRef: attrsRef)
        case let oid as ObjectID:
            note = try? repository.note(for: oid, notesRef: attrsRef)
        case let string as String:
            if let oid = ObjectID(string: string) {
                note = try? repository.note(for: oid, notesRef: attrsRef)
            } else if let object = try? repository.object(parsing: string) {
                note = try? repository.note(for: object.oid, notesRef: attrsRef)
            } else {
                fallthrough
            }
        default:
            return nil
        }

        guard let note else { return nil }
        guard arguments.count > 0 else { return note }

        guard arguments.count == 1, let key = arguments.first as? String else {
            if arguments.first == nil {
                // We know that arguments.count > 0, so arguments.first must be nil, which we'll allow in case somebody
                // was trying to lookup a config key value and the config key ended up being nil.
                return nil
            }

            throw TemplateSyntaxError("""
                'attrs' allows one argument, which must be a string.
                """)
        }

        let (_, trailers) = try ConventionalCommit.Trailer.trailers(from: note.message)
        guard let value = trailers.first(where: { $0.key == key })?.value else {
            return nil
        }

        return value
    }

    func olderThan(_ value: Any?, _ arguments: [Any]) throws -> Any? {
        guard arguments.count == 1,
              let string = arguments.first as? String,
              let timeInterval = TimeInterval(string: string) else {
            throw TemplateSyntaxError("""
                'olderThan' requires one argument, which must be a string representing a time interval in a string \
                format such as "9d", "9d3h", "9d3m", "7w2d30", etc.
                """
            )
        }

        let date: Date
        switch value {
        case let tag as Tagish:
            date = tag.tagger.time
        case let commit as Commitish:
            date = commit.date
        case let note as Note:
            date = note.committer.time
        case nil:
            return false
        default:
            return nil
        }

        return (-date.timeIntervalSinceNow) > timeInterval
    }

    func revParse(_ value: Any?) throws -> Any? {
        switch value {
        case let oid as ObjectID:
            return try? repository.object(oid)
        case let pointer as any PointerType:
            return try? repository.object(pointer.oid)
        case let string as String:
            if let oid = ObjectID(string: string) {
                return try? repository.object(oid)
            } else {
                return try? repository.object(parsing: string)
            }
        default:
            throw TemplateSyntaxError("""
                'rev_parse' requires a string value or object ID.
                """)
        }
    }

    func objectType(_ value: Any?) throws -> Any? {
        let oid: ObjectID
        switch value {
        case let value as String:
            guard let value = ObjectID(string: value) else {
                throw TemplateSyntaxError("'\(value)' is not a valid object ID.")
            }

            oid = value
        case let value as ObjectID:
            oid = value
        default:
            throw TemplateSyntaxError("""
                'object_type' requires a value, which must be either a string or an object ID.
                """)
        }

        guard let object = try? repository.object(oid) else {
            return nil
        }

        return String(describing: type(of: object).type)
    }

    func commits(_ value: Any?) throws -> Any? {
        guard let value = value as? (any ObjectType) else {
            throw TemplateSyntaxError("""
                'commits' requires a value, which must be a Git object type.
                """)
        }

        switch value {
        case let value as Tagish:
            return try? repository.commits(from: value.target.oid, since: nil)
        case let value as Commitish:
            return try? repository.commits(from: value.oid, since: nil)
        default:
            throw TemplateSyntaxError("""
                'commits' doesn't know how to get commits from a '\(type(of: value))'.
                """)
        }
    }

    func alias(_ value: Any?, _ arguments: [Any]) throws -> Any? {
        guard let contact = value as? String,
              case var components = contact.split(separator: " <"),
              components.count == 2,
              components.last?.last == ">" else {
            throw TemplateSyntaxError("""
                'alias' requires one value, which must be a name and email in the format 'Jane Doe <jdoe@example.org>'.
                """)
        }

        let name = components[0].trimmingCharacters(in: .whitespaces)
        components[1].removeLast() // Remove trailing '>'
        let email = String(components[1])

        if let argument = arguments.first {
            guard arguments.count == 0, let platform = argument as? String else {
                throw TemplateSyntaxError("""
                    'alias' allows one argument, which must be a platform like 'gitlab' or 'slack'.
                    """)
            }

            return try? aliasMap?.alias(name: name, email: email, platform: platform)
        }

        return try? aliasMap?.resolve(name: name, email: email)
    }

    func random(_ value: Any?) throws -> Any? {
        guard let value = value as? any Collection else {
            throw TemplateSyntaxError("""
                'random' takes one value, which must be a collection.
                """
            )
        }

        return value.randomElement()
    }

    func prefix(_ value: Any?, arguments: [Any]) throws -> Any? {
        guard arguments.count == 0 || arguments.first is Int else {
            throw TemplateSyntaxError("""
                'prefix' allows one argument, which must be an integer.
                """)
        }

        switch value {
        case let value as String:
            let result = value.prefix(arguments.first as? Int ?? 1)
            return String(result)
        case let value as [Any]:
            let result = value.prefix(arguments.first as? Int ?? 1)
            return Array(result)
        case let value as any Collection:
            return value.prefix(arguments.first as? Int ?? 1) as any Collection
        case nil:
            return ""
        default:
            return String(describing: value!).prefix(arguments.first as? Int ?? 1)
        }
    }

    func replace(_ value: Any?, arguments: [Any]) throws -> Any? {
        guard let substring = arguments.first as? String, let replacement = arguments.second as? String else {
            throw TemplateSyntaxError("""
                'replace' requires two arguments, which must strings.
                """)
        }

        guard let value = value as? String else {
            throw TemplateSyntaxError("""
                'replace' takes one value, which must be a string.
                """
            )
        }

        return value.replacingOccurrences(of: substring, with: replacement)
    }

    func formatDate(_ value: Any?, arguments: [Any]) throws -> Any? {
        guard arguments.count == 0 || arguments.first is String else {
            throw TemplateSyntaxError("""
                The first argument to 'format_date' must be a string.
                """)
        }

        guard arguments.count < 2 || arguments.second is Bool else {
            throw TemplateSyntaxError("""
                The first argument to 'format_date' must be a bool.
                """)
        }

        let gmt = (arguments.second as? Bool) ?? false

        guard let value = value as? Date else {
            throw TemplateSyntaxError("""
                'format_date' takes one value, which must be a date.
                """
            )
        }

        let dateFormat = arguments.first as? String ?? String.gitDateFormat
        dateFormatter.dateFormat = dateFormat
        dateFormatter.timeZone = gmt ? .gmt : .autoupdatingCurrent
        return dateFormatter.string(from: value)
    }

    func parseDate(_ value: Any?, arguments: [Any]) throws -> Any? {
        guard arguments.count == 0 || arguments.first is String else {
            throw TemplateSyntaxError("""
                'parse_date' allows one argument, which must be a string.
                """)
        }

        guard let value = value as? String else {
            throw TemplateSyntaxError("""
                'parse_date' takes one value, which must be a string.
                """
            )
        }

        let dateFormat = arguments.first as? String ?? String.gitDateFormat
        dateFormatter.dateFormat = dateFormat
        return dateFormatter.date(from: value)
    }

    func formatMarkdown(_ value: Any?) throws -> Any? {
        guard let value = value as? String else {
            throw TemplateSyntaxError("""
                'format_markdown' takes one value, which must be a string.
                """
            )
        }

        var formatter = MarkdownToHTML()
        let document = Document(parsing: value)
        return formatter.visit(document)
    }

    public let repository: Repositoryish
    public let train: Trains.TrainImpl?

    private lazy var aliasMap: AliasMap? = try? repository.aliasMap()
    private lazy var dateFormatter = DateFormatter()

    public init(
        _ repository: Repositoryish,
        train: Trains.TrainImpl?
    ) {
        self.repository = repository
        self.train = train

        super.init()

        registerFilter("get", filter: `get`)
        registerFilter("contains", filter: contains)
        registerFilter("attrs", filter: attrs)
        registerFilter("older_than", filter: olderThan)
        registerFilter("rev_parse", filter: revParse)
        registerFilter("object_type", filter: objectType)
        registerFilter("commits", filter: commits)
        registerFilter("alias", filter: alias)
        registerFilter("random", filter: random)
        registerFilter("prefix", filter: self.prefix)
        registerFilter("replace", filter: replace)
        registerFilter("parse_date", filter: parseDate)
        registerFilter("format_date", filter: formatDate)
        registerFilter("format_markdown", filter: formatMarkdown)
    }
}

extension Stencil.Environment {
    static let yamlHeadersKey = "headers"

    /// This is so we can get at the repository and options that we were initialized with.
    var templateExtension: TemplateExtension {
        extensions.first(where: { $0 is TemplateExtension }) as! TemplateExtension
    }

    var repository: Repositoryish {
        templateExtension.repository
    }

    var train: Trains.TrainImpl? {
        templateExtension.train
    }

    public init(
        repository: Repositoryish,
        train: Trains.TrainImpl?,
        urls: [URL]
    ) {
        self = Stencil.Environment(
           loader: TemplateLoader(urls: urls),
           extensions: [
               TemplateExtension(
                   repository,
                   train: train
               )
           ],
           trimBehaviour: .smart
       )
    }

    /// Render a single template, or multiple templates if the name corresponds to a directory in one of the specified
    /// template directories.
    ///
    /// Nil entries represent files that were not templates, but should be copied over as resources from the original
    /// template directory.
    ///
    /// - Note: assumes that the environment is using a `TemplateLoader`.
    public func renderTemplates(
        nameOrRoot: String,
        additionalContext: [String: Any]
    ) throws -> [String: String?] {
        let loader = self.loader as! TemplateLoader
        let templates = try loader.loadTemplates(nameOrRoot: nameOrRoot, environment: self)

        var result: [String: String?] = [:]
        for (subpath, contents) in templates {
            guard let (template, headers) = contents else {
                result[subpath] = .some(nil)
                continue
            }

            var context = additionalContext
            if let headers, context[Self.yamlHeadersKey] == nil {
                context[Self.yamlHeadersKey] = headers
            }

            result[subpath] = try template.render(context)
        }

        return result
    }
}

public enum TemplateError: Error, CustomStringConvertible {
    case notFound
    case userError(String)

    public var description: String {
        switch self {
        case .notFound:
            return "Template not found."
        case let .userError(errorString):
            return errorString
        }
    }
}

extension Pointer: CustomStencilSubscriptable {
    public subscript(key: String) -> String? {
        switch key {
        case "oid":
            return oid.description
        case "type":
            return String(describing: type)
        default:
            return nil
        }
    }
}

/// Not used for anything except letting `Bundle` figure out where we are.
class LHCBundle {
}
