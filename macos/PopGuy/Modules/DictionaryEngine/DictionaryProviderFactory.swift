// DictionaryProviderFactory.swift
// PopGuy — DictionaryEngine
//
// Maps DictionaryProviderKind to a concrete DictionaryProvider adapter.

import Foundation

// MARK: - DictionaryProviderFactory

nonisolated enum DictionaryProviderFactory {
    static func make(_ kind: DictionaryProviderKind) -> any DictionaryProvider {
        switch kind {
        case .macOSBuiltin:
            MacOSBuiltinDictionaryProvider()
        case .minhqnd:
            MinhqndDictionaryProvider()
        case .freeDictionaryAPI:
            FreeDictionaryAPIProvider()
        case .babylonBGL:
            BabylonBGLDictionaryProvider(dictionaries: [])
        }
    }
}
