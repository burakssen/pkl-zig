// Note: This file is a port of the original Go implementation to Zig.
// Ported to Zig by Burak Şen, 2026
//===----------------------------------------------------------------------===//
// Copyright © 2024-2025 Apple Inc. and the Pkl project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

/// Message codes for the Pkl Message API.
pub const Code = enum(i64) {
    new_evaluator_response = 0x21,
    evaluate_response = 0x24,
    evaluate_log = 0x25,
    evaluate_read = 0x26,
    evaluate_read_module = 0x28,
    list_resources_request = 0x2a,
    list_modules_request = 0x2c,
    initialize_module_reader_request = 0x2e,
    initialize_resource_reader_request = 0x30,
    close_external_process = 0x32,
};
