/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

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
            } else if (entry.path().extension() == ".k") {
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
