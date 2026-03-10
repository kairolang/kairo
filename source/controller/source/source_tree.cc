///--- The Kairo Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: Apache-2.0                                                        ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#include <iostream>

#include "controller/include/shared/file_system.hh"

__CONTROLLER_FS_BEGIN {
    SourceTree::SourceTree(const std::string &rootPath)
        : root(Node(rootPath)) {
        buildTree(rootPath, root);
    }

    void SourceTree::print() const { printTree(root); }

    bool SourceTree::buildTree(const std::string &dirPath, Node &node) {
        bool containsKairoFiles = false;
        for (const auto &entry : std::filesystem::directory_iterator(dirPath)) {
            if (entry.is_directory()) {
                Node dirNode(entry.path().string());
                if (buildTree(entry.path().string(), dirNode)) {
                    node.children.push_back(std::move(dirNode));
                    containsKairoFiles = true;
                }
            } else if (entry.path().extension() == ".kro") {
                node.children.emplace_back(entry.path().string());
                containsKairoFiles = true;
            }
        }
        return containsKairoFiles;
    }

    void SourceTree::printTree(const Node &node, const std::string &prefix) const {
        std::cout << prefix << node.path << "\n";
        for (const auto &child : node.children) {
            printTree(child, prefix + "  ");
        }
    }

}  // __CONTROLLER_FS_BEGIN
