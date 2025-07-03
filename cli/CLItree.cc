#include <algorithm>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

struct TokenizedCommand {
  std::string keyword;
  std::vector<std::string> arguments;
  std::vector<std::string> flags;
};

TokenizedCommand tokenize(const std::string &input) {
  TokenizedCommand cmd;
  if (input.empty())
    return cmd;

  std::istringstream iss(input);
  std::string token;

  if (!std::getline(iss, token, ' '))
    return cmd;

  // Get keyword if not a flag
  if (std::getline(iss, token, ' ') && !token.empty() && token[0] != '-') {
    cmd.keyword = token;
  } else {
    iss = std::istringstream(token + (iss.eof() ? "" : " " + iss.str()));
  }

  // Process tokens
  while (std::getline(iss, token, ' ')) {
    if (token.empty())
      continue;

    if (token[0] == '-') {
      std::vector<std::string> flags;
      size_t pos = 0;
      bool double_dash = token.size() > 1 && token[1] == '-';
      size_t prefix_len = double_dash ? 2 : 1;

      // Split flags with same - or --
      while (pos < token.size()) {
        if (pos == 0) {
          pos = prefix_len;
        } else if (double_dash && pos + 1 < token.size() && token[pos] == '-' &&
                   token[pos + 1] == '-') {
          flags.push_back(token.substr(0, pos));
          token.erase(0, pos);
          pos = 2;
          double_dash = true;
        } else if (!double_dash && pos < token.size() && token[pos] == '-') {
          flags.push_back(token.substr(0, pos));
          token.erase(0, pos);
          pos = 1;
          double_dash = false;
        } else {
          ++pos;
        }
      }
      if (pos > prefix_len)
        flags.push_back(token);

      // Validate flags
      for (const auto &flag : flags) {
        size_t start =
            (flag[0] == '-' && flag.size() > 1 && flag[1] == '-') ? 2 : 1;
        if (flag.size() <= start)
          continue;

        bool valid = true;
        size_t i = start;
        while (i < flag.size() && flag[i] != '=') {
          if (!std::isalnum(flag[i]) && flag[i] != '-')
            valid = false;
          ++i;
        }
        if (flag[i] == '=' && i + 1 == flag.size())
          valid = false;
        if (valid)
          cmd.flags.push_back(flag);
      }
    } else {
      // Validate argument
      bool valid = true;
      for (char c : token) {
        if (!std::isalnum(c) && c != '_' && c != '.' && c != ':' && c != '/' &&
            c != '\\') {
          valid = false;
          break;
        }
      }
      if (valid && !token.empty())
        cmd.arguments.push_back(token);
    }
  }

  return cmd;
}

class CLItree {
private:
  struct node {
    std::string word;
    std::vector<std::string> flagList;
  };

  std::vector<node> keywords;

  int findKeywordIndex(const std::string &keyword) const {
    for (size_t i = 0; i < keywords.size(); ++i) {
      if (keywords[i].word == keyword)
        return i;
    }
    return -1;
  }

public:
  CLItree() {
    // Default keyword for commands without an explicit keyword
    keywords.push_back({"__default", {}});
  }

  void addKeyword(const std::string &word) {
    if (findKeywordIndex(word) == -1) {
      keywords.push_back({word, {}});
    }
  }

  void addFlag(const std::string &keyword,
               const std::vector<std::string> &newFlags) {
    int idx = findKeywordIndex(keyword);
    if (idx == -1)
      return;

    std::vector<std::string> &flags = keywords[idx].flagList;

    for (const auto &flag : newFlags) {
      bool exists = false;
      for (const auto &f : flags) {
        if (f == flag) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        flags.push_back(flag);
      }
    }
  }

  void run(std::string command) {
    TokenizedCommand cmnd = tokenize(command);
    std::string actualKeyword =
        cmnd.keyword.empty() ? "__default" : cmnd.keyword;
    int idx = findKeywordIndex(actualKeyword);
    if (idx == -1) {
      std::cout << "fail :(" << std::endl;
      return;
    }

    node keyword = keywords[idx];
    bool isFlagValid = true;

    for (const std::string &flag : cmnd.flags) {
      if (std::find(keyword.flagList.begin(), keyword.flagList.end(), flag) ==
          keyword.flagList.end()) {
        isFlagValid = false;
      }
    }
    if (isFlagValid) {
      std::cout << "it runs!!" << std::endl;
    } else {
      std::cout << "fail :(" << std::endl;
    }
  }

  void execute(std::string keyword, std::vector<std::string> flags,
               std::vector<std::string> args);
};

int main() {
  // Create a CLItree instance
  CLItree cli;

  // Add keywords and flags
  cli.addKeyword("build");
  cli.addFlag("build", {"--release", "--debug", "-v"});

  cli.addKeyword("test");
  cli.addFlag("test", {"--unit", "--integration", "-q"});

  // Test case 1: Valid command with valid flags
  std::cout << "Test 1: Running 'build --release -v project1'\n";
  cli.run("helix build --release -v project1");

  // Test case 2: Valid command with no flags
  std::cout << "\nTest 2: Running 'build project1'\n";
  cli.run("helix build project1");

  // Test case 3: Invalid flag
  std::cout << "\nTest 3: Running 'build --invalid project1'\n";
  cli.run("helix build --invalid project1");

  // Test case 4: Valid command for 'test' keyword
  std::cout << "\nTest 4: Running 'test --unit -q module1'\n";
  cli.run("helix test --unit -q module1");

  // Test case 5: Non-existent keyword
  std::cout << "\nTest 5: Running 'deploy --force server'\n";
  cli.run("helix deploy --force server");

  cli.addFlag("__default", {"--version", "-h"});
  cli.run("helix --version"); 

  return 0;
}
