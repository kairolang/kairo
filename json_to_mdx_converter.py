#!/usr/bin/env python3
"""
JSON to MDX Converter for Helix Language Documentation
Converts JSON API documentation to MDX files for Starlight documentation system.
"""

import json
import os
from pathlib import Path
from typing import Dict, List, Any, Optional
import re

class MDXConverter:
    def __init__(self, output_dir: str = "docs"):
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(exist_ok=True)
        
    def sanitize_filename(self, name: str) -> str:
        """Convert a name to a valid filename."""
        # Remove template parameters and special characters
        name = re.sub(r'<[^>]*>', '', name)
        name = re.sub(r'[^\w\-_]', '-', name)
        name = re.sub(r'-+', '-', name)
        return name.strip('-').lower()
    
    def format_signature(self, signature: str) -> str:
        """Format function signatures for better readability."""
        return signature.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    
    def format_description(self, description: str) -> str:
        """Format descriptions with proper markdown."""
        if not description:
            return ""
        return description.strip()
    
    def create_frontmatter(self, title: str, description: str = "", sidebar_position: int = None) -> str:
        """Create frontmatter for MDX files."""
        frontmatter = "---\n"
        frontmatter += f"title: {title}\n"
        if description:
            frontmatter += f"description: {description}\n"
        if sidebar_position is not None:
            frontmatter += f"sidebar:\n  order: {sidebar_position}\n"
        frontmatter += "---\n\n"
        return frontmatter
    
    def create_method_mdx(self, method: Dict[str, Any], class_name: str, namespace: str) -> str:
        """Create MDX content for a single method."""
        method_name = method.get('name', '')
        description = self.format_description(method.get('description', ''))
        signature = self.format_signature(method.get('signature', ''))
        specifiers = method.get('specifiers', [])
        attributes = method.get('attributes', [])
        
        # Create proper title with namespace
        title = f"{namespace}::{class_name}::{method_name}"
        
        content = self.create_frontmatter(title, description)
        
        # Add method header
        content += f"# {method_name}\n\n"
        
        if description:
            content += f"{description}\n\n"
        
        # Add signature
        content += "## Signature\n\n"
        content += f"```cpp\n{signature}\n```\n\n"
        
        # Add specifiers if any
        if specifiers:
            content += "## Specifiers\n\n"
            for spec in specifiers:
                content += f"- `{spec}`\n"
            content += "\n"
        
        # Add attributes if any
        if attributes:
            content += "## Attributes\n\n"
            for attr in attributes:
                content += f"- `{attr}`\n"
            content += "\n"
        
        # Add return link
        content += f"## See Also\n\n"
        content += f"[Back to {class_name}](../{self.sanitize_filename(class_name)})\n\n"
        
        return content
    
    def create_operator_mdx(self, operator: Dict[str, Any], class_name: str, namespace: str) -> str:
        """Create MDX content for a single operator."""
        op_name = operator.get('name', '')
        description = self.format_description(operator.get('description', ''))
        signature = self.format_signature(operator.get('signature', ''))
        specifiers = operator.get('specifiers', [])
        
        # Create proper title with namespace
        title = f"{namespace}::{class_name}::{op_name}"
        
        content = self.create_frontmatter(title, description)
        
        # Add operator header
        content += f"# {op_name}\n\n"
        
        if description:
            content += f"{description}\n\n"
        
        # Add signature
        content += "## Signature\n\n"
        content += f"```cpp\n{signature}\n```\n\n"
        
        # Add specifiers if any
        if specifiers:
            content += "## Specifiers\n\n"
            for spec in specifiers:
                content += f"- `{spec}`\n"
            content += "\n"
        
        # Add return link
        content += f"## See Also\n\n"
        content += f"[Back to {class_name}](../{self.sanitize_filename(class_name)})\n\n"
        
        return content
    
    def create_constructor_mdx(self, constructor: Dict[str, Any], class_name: str, namespace: str) -> str:
        """Create MDX content for a single constructor."""
        ctor_name = constructor.get('name', '')
        description = self.format_description(constructor.get('description', ''))
        signature = self.format_signature(constructor.get('signature', ''))
        specifiers = constructor.get('specifiers', [])
        
        # Create proper title with namespace
        title = f"{namespace}::{class_name}::{ctor_name} (Constructor)"
        
        content = self.create_frontmatter(title, description)
        
        # Add constructor header
        content += f"# {ctor_name} (Constructor)\n\n"
        
        if description:
            content += f"{description}\n\n"
        
        # Add signature
        content += "## Signature\n\n"
        content += f"```cpp\n{signature}\n```\n\n"
        
        # Add specifiers if any
        if specifiers:
            content += "## Specifiers\n\n"
            for spec in specifiers:
                content += f"- `{spec}`\n"
            content += "\n"
        
        # Add return link
        content += f"## See Also\n\n"
        content += f"[Back to {class_name}](../{self.sanitize_filename(class_name)})\n\n"
        
        return content
    
    def create_class_mdx(self, class_data: Dict[str, Any], namespace: str) -> str:
        """Create MDX content for a class overview."""
        class_name = class_data.get('name', '')
        description = self.format_description(class_data.get('description', ''))
        template_params = class_data.get('template_parameters', [])
        
        # Create proper title with namespace
        title = f"{namespace}::{class_name}"
        
        content = self.create_frontmatter(title, description)
        
        # Add class header
        content += f"# {class_name}\n\n"
        
        if description:
            content += f"{description}\n\n"
        
        # Add template parameters if any
        if template_params:
            content += "## Template Parameters\n\n"
            for param in template_params:
                content += f"- `{param}`\n"
            content += "\n"
        
        # Add type aliases if any
        type_aliases = class_data.get('type_aliases', [])
        if type_aliases:
            content += "## Type Aliases\n\n"
            for alias in type_aliases:
                content += f"- `{alias}`\n"
            content += "\n"
        
        # Add enums if any
        enums = class_data.get('enums', [])
        if enums:
            content += "## Enums\n\n"
            for enum in enums:
                enum_name = enum.get('name', '')
                enum_desc = enum.get('description', '')
                content += f"### {enum_name}\n\n"
                if enum_desc:
                    content += f"{enum_desc}\n\n"
                
                values = enum.get('values', [])
                if values:
                    content += "#### Values\n\n"
                    for value in values:
                        val_name = value.get('name', '')
                        val_desc = value.get('description', '')
                        content += f"- **{val_name}**: {val_desc}\n"
                    content += "\n"
        
        # Add private members if any
        private_members = class_data.get('private_members', [])
        if private_members:
            content += "## Private Members\n\n"
            for member in private_members:
                member_name = member.get('name', '')
                member_type = member.get('type', '')
                member_desc = member.get('description', '')
                default_val = member.get('default', '')
                
                content += f"### {member_name}\n\n"
                content += f"- **Type**: `{member_type}`\n"
                if member_desc:
                    content += f"- **Description**: {member_desc}\n"
                if default_val:
                    content += f"- **Default**: `{default_val}`\n"
                content += "\n"
        
        # Add constructors section
        constructors = class_data.get('constructors', [])
        if constructors:
            content += "## Constructors\n\n"
            for i, constructor in enumerate(constructors):
                ctor_name = constructor.get('name', '')
                ctor_desc = constructor.get('description', '')
                ctor_sig = constructor.get('signature', '')
                
                filename = f"{self.sanitize_filename(ctor_name)}-{i+1}"
                content += f"### [{ctor_name}](./{self.sanitize_filename(class_name)}/constructors/{filename})\n\n"
                if ctor_desc:
                    content += f"{ctor_desc}\n\n"
                content += f"```cpp\n{ctor_sig}\n```\n\n"
        
        # Add operators section
        operators = class_data.get('operators', [])
        if operators:
            content += "## Operators\n\n"
            for i, operator in enumerate(operators):
                op_name = operator.get('name', '')
                op_desc = operator.get('description', '')
                op_sig = operator.get('signature', '')
                
                filename = f"{self.sanitize_filename(op_name)}-{i+1}"
                content += f"### [{op_name}](./{self.sanitize_filename(class_name)}/operators/{filename})\n\n"
                if op_desc:
                    content += f"{op_desc}\n\n"
                content += f"```cpp\n{op_sig}\n```\n\n"
        
        # Add methods section
        methods = class_data.get('methods', [])
        if methods:
            content += "## Methods\n\n"
            for i, method in enumerate(methods):
                method_name = method.get('name', '')
                method_desc = method.get('description', '')
                method_sig = method.get('signature', '')
                
                filename = f"{self.sanitize_filename(method_name)}-{i+1}"
                content += f"### [{method_name}](./{self.sanitize_filename(class_name)}/methods/{filename})\n\n"
                if method_desc:
                    content += f"{method_desc}\n\n"
                content += f"```cpp\n{method_sig}\n```\n\n"
        
        # Add example if available
        example = class_data.get('example', {})
        if example:
            content += "## Example\n\n"
            main_example = example.get('main', '')
            if main_example:
                content += "```cpp\n"
                content += main_example
                content += "\n```\n\n"
        
        return content
    
    def create_function_mdx(self, function: Dict[str, Any], namespace: str) -> str:
        """Create MDX content for a standalone function."""
        func_name = function.get('name', '')
        description = self.format_description(function.get('description', ''))
        signature = self.format_signature(function.get('signature', ''))
        specifiers = function.get('specifiers', [])
        template_params = function.get('template_parameters', [])
        
        # Create proper title with namespace
        title = f"{namespace}::{func_name}"
        
        content = self.create_frontmatter(title, description)
        
        # Add function header
        content += f"# {func_name}\n\n"
        
        if description:
            content += f"{description}\n\n"
        
        # Add template parameters if any
        if template_params:
            content += "## Template Parameters\n\n"
            for param in template_params:
                content += f"- `{param}`\n"
            content += "\n"
        
        # Add signature
        content += "## Signature\n\n"
        content += f"```cpp\n{signature}\n```\n\n"
        
        # Add specifiers if any
        if specifiers:
            content += "## Specifiers\n\n"
            for spec in specifiers:
                content += f"- `{spec}`\n"
            content += "\n"
        
        # Add example if available
        example = function.get('example', {})
        if example:
            content += "## Example\n\n"
            main_example = example.get('main', '')
            if main_example:
                content += "```cpp\n"
                content += main_example
                content += "\n```\n\n"
        
        return content
    
    def create_namespace_index(self, namespace: str, description: str, classes: List[Dict], functions: List[Dict]) -> str:
        """Create the main namespace index file."""
        title = f"{namespace} Namespace"
        
        content = self.create_frontmatter(title, description)
        
        content += f"# {namespace}\n\n"
        
        if description:
            content += f"{description}\n\n"
        
        # Add classes section
        if classes:
            content += "## Classes\n\n"
            for class_data in classes:
                class_name = class_data.get('name', '')
                class_desc = class_data.get('description', '')
                
                content += f"### [{class_name}](./{self.sanitize_filename(class_name)})\n\n"
                if class_desc:
                    content += f"{class_desc}\n\n"
        
        # Add functions section
        if functions:
            content += "## Functions\n\n"
            for function in functions:
                func_name = function.get('name', '')
                func_desc = function.get('description', '')
                
                content += f"### [{func_name}](./functions/{self.sanitize_filename(func_name)})\n\n"
                if func_desc:
                    content += f"{func_desc}\n\n"
        
        return content
    
    def convert_json_to_mdx(self, json_file_path: str):
        """Convert JSON file to MDX files."""
        with open(json_file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        namespace = data.get('namespace', 'Unknown')
        description = data.get('description', '')
        classes = data.get('classes', [])
        functions = data.get('functions', [])
        
        # Create namespace directory
        namespace_dir = self.output_dir / self.sanitize_filename(namespace.replace('::', '-'))
        namespace_dir.mkdir(exist_ok=True)
        
        # Create namespace index
        index_content = self.create_namespace_index(namespace, description, classes, functions)
        with open(namespace_dir / 'index.mdx', 'w', encoding='utf-8') as f:
            f.write(index_content)
        
        # Process classes
        for class_data in classes:
            class_name = class_data.get('name', '')
            sanitized_class_name = self.sanitize_filename(class_name)
            
            # Create class directory
            class_dir = namespace_dir / sanitized_class_name
            class_dir.mkdir(exist_ok=True)
            
            # Create class overview
            class_content = self.create_class_mdx(class_data, namespace)
            with open(class_dir / 'index.mdx', 'w', encoding='utf-8') as f:
                f.write(class_content)
            
            # Create constructors
            constructors = class_data.get('constructors', [])
            if constructors:
                constructors_dir = class_dir / 'constructors'
                constructors_dir.mkdir(exist_ok=True)
                
                for i, constructor in enumerate(constructors):
                    ctor_name = constructor.get('name', '')
                    filename = f"{self.sanitize_filename(ctor_name)}-{i+1}.mdx"
                    ctor_content = self.create_constructor_mdx(constructor, class_name, namespace)
                    with open(constructors_dir / filename, 'w', encoding='utf-8') as f:
                        f.write(ctor_content)
            
            # Create operators
            operators = class_data.get('operators', [])
            if operators:
                operators_dir = class_dir / 'operators'
                operators_dir.mkdir(exist_ok=True)
                
                for i, operator in enumerate(operators):
                    op_name = operator.get('name', '')
                    filename = f"{self.sanitize_filename(op_name)}-{i+1}.mdx"
                    op_content = self.create_operator_mdx(operator, class_name, namespace)
                    with open(operators_dir / filename, 'w', encoding='utf-8') as f:
                        f.write(op_content)
            
            # Create methods
            methods = class_data.get('methods', [])
            if methods:
                methods_dir = class_dir / 'methods'
                methods_dir.mkdir(exist_ok=True)
                
                for i, method in enumerate(methods):
                    method_name = method.get('name', '')
                    filename = f"{self.sanitize_filename(method_name)}-{i+1}.mdx"
                    method_content = self.create_method_mdx(method, class_name, namespace)
                    with open(methods_dir / filename, 'w', encoding='utf-8') as f:
                        f.write(method_content)
        
        # Process standalone functions
        if functions:
            functions_dir = namespace_dir / 'functions'
            functions_dir.mkdir(exist_ok=True)
            
            for function in functions:
                func_name = function.get('name', '')
                filename = f"{self.sanitize_filename(func_name)}.mdx"
                func_content = self.create_function_mdx(function, namespace)
                with open(functions_dir / filename, 'w', encoding='utf-8') as f:
                    f.write(func_content)
        
        print(f"Successfully converted {json_file_path} to MDX files in {namespace_dir}")

def main():
    """Main function to run the converter."""
    import argparse
    
    parser = argparse.ArgumentParser(description='Convert JSON API documentation to MDX files')
    parser.add_argument('json_file', help='Path to the JSON file to convert')
    parser.add_argument('--output', '-o', default='docs', help='Output directory for MDX files')
    
    args = parser.parse_args()
    
    converter = MDXConverter(args.output)
    converter.convert_json_to_mdx(args.json_file)

if __name__ == '__main__':
    main()
