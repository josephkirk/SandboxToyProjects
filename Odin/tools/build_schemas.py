import os
import subprocess
import re
from pathlib import Path

# Configuration
SCRIPT_DIR = Path(__file__).parent.resolve()
# g:\Projects\SandboxDev\thirdparties\Windows.flatc.binary\flatc.exe
FLATC_PATH = SCRIPT_DIR / r"..\..\..\thirdparties\Windows.flatc.binary\flatc.exe"
# ../.. from tools is SandboxDev? 
# Tools in Odin/tools
# .. -> Odin
# .. -> SandboxDev
# So ../../ is SandboxDev.
# SCRIPT_DIR is g:\Projects\SandboxDev\Odin\tools
# FLATC is g:\Projects\SandboxDev\thirdparties\...
# So ..\..\thirdparties is correct?
# User said: g:\Projects\SandboxDev\thirdparties
# SCRIPT_DIR: g:\Projects\SandboxDev\Odin\tools
# REL: ..\..\thirdparties
# Let's just trust ..\..\thirdparties.
FLATC_PATH = SCRIPT_DIR / r"..\..\thirdparties\Windows.flatc.binary\flatc.exe"
SCHEMA_DIR = SCRIPT_DIR / r"..\schemas"
# Target Project Source Generated Directory
# Game Module (Specific)
UE_GAME_DIR = SCRIPT_DIR / r"..\renderer\OdinRender\Source\OdinRender\Generated"
ODIN_OUT_DIR = SCRIPT_DIR / r"..\game\generated"

def run_flatc(schema_file):
    # Generate C++ for Unreal
    cmd = [
        str(FLATC_PATH),
        "--cpp",
        "--cpp-std", "c++17",
        "--gen-object-api",
        "--filename-suffix", "_flatbuffer",
        "-o", str(UE_GAME_DIR),
        str(schema_file)
    ]
    print(f"Running flatc (C++): {' '.join(cmd)}")
    subprocess.check_call(cmd)

class SchemaParser:
    def __init__(self, content):
        self.content = content
        self.tables = []
        self.structs = []
        self.enums = []
        self.parse()

    def parse(self):
        # Remove comments
        text = re.sub(r"//.*", "", self.content)
        
        # Parse structs
        for match in re.finditer(r"struct\s+(\w+)\s*{([^}]*)}", text, re.MULTILINE | re.DOTALL):
            name = match.group(1)
            body = match.group(2)
            fields = self.parse_fields(body)
            self.structs.append((name, fields))

        # Parse tables
        for match in re.finditer(r"table\s+(\w+)\s*{([^}]*)}", text, re.MULTILINE | re.DOTALL):
            name = match.group(1)
            body = match.group(2)
            fields = self.parse_fields(body)
            self.tables.append((name, fields))

    def parse_fields(self, body):
        fields = []
        for match in re.finditer(r"\s*(\w+):\s*([\[\]\w\.]+);", body):
            fields.append((match.group(1), match.group(2)))
        return fields

def gen_ue_wrappers(parser, table_list):
    header = """#pragma once
#include "CoreMinimal.h"
#include "UObject/NoExportTypes.h"
#include "GameState_flatbuffer.h"
#include "GameStateWrappers.generated.h"

"""
    cpp = """#include "GameStateWrappers.h"
"""

    for name, fields in parser.tables:
        wrapper_name = f"F{name}Wrapper" # UStruct convention F prefix
        
        header += f"""USTRUCT(BlueprintType)
struct {wrapper_name}
{{
    GENERATED_BODY()

"""
        # Properties
        for fname, ftype in fields:
            ue_type = "int32"
            if ftype == "int": ue_type = "int32"
            elif ftype == "float": ue_type = "float"
            elif ftype == "bool": ue_type = "bool"
            elif "Vec2" in ftype: ue_type = "FVector2D"
            elif ftype == "Player" or ftype == "Enemy": ue_type = f"F{ftype}Wrapper"
            elif "GameEventType" in ftype: ue_type = "int32" # Enum as int for simplicity or specific enum
            
            if "[" in ftype: # Array
                inner_type = ftype.replace("[","").replace("]","")
                if inner_type == "Enemy": ue_type = f"TArray<F{inner_type}Wrapper>"
                else: ue_type = f"TArray<int32>" # Simplification, expand if needed

            header += f"    UPROPERTY(BlueprintReadWrite, Category = \"Odin|{name}\")\n"
            header += f"    {ue_type} {fname.title()};\n\n"

        # UpdateFrom Method
        header += f"    void UpdateFrom(const VS::Schema::{name}* InBuffer);\n"
        header += "};\n\n"

        # CPP Implementation of UpdateFrom
        cpp += f"void {wrapper_name}::UpdateFrom(const VS::Schema::{name}* InBuffer)\n{{\n"
        cpp += "    if (!InBuffer) return;\n"
        
        for fname, ftype in fields:
            # Scalar mapping
            if ftype in ["int", "float", "bool"]:
                cpp += f"    {fname.title()} = InBuffer->{fname}();\n"
            elif "Vec2" in ftype:
                cpp += f"    if (InBuffer->{fname}()) {fname.title()} = FVector2D(InBuffer->{fname}()->x(), InBuffer->{fname}()->y());\n"
            elif ftype in ["Player", "Enemy"]: # Nested table
                 cpp += f"    if (InBuffer->{fname}()) {fname.title()}.UpdateFrom(InBuffer->{fname}());\n"
            elif "[" in ftype: # Array of tables (Enemies)
                inner_type = ftype.replace("[","").replace("]","")
                if inner_type == "Enemy":
                    cpp += f"""    if (InBuffer->{fname}()) {{
        {fname.title()}.SetNum(InBuffer->{fname}()->size());
        for (uint32 i = 0; i < InBuffer->{fname}()->size(); ++i) {{
            if (InBuffer->{fname}()->Get(i)) {{
                {fname.title()}[i].UpdateFrom(InBuffer->{fname}()->Get(i));
            }}
        }}
    }}
"""
        cpp += "}\n\n"

    with open(f"{UE_GAME_DIR}/GameStateWrappers.h", "w") as f: f.write(header)
    with open(f"{UE_GAME_DIR}/GameStateWrappers.cpp", "w") as f: f.write(cpp)
    print("Generated Unreal UStruct Wrappers.")

def gen_odin_code(parser):
    code = """package generated

import "core:fmt"
import fb "../flatbuffers"

"""
    # Structs (just definitions)
    for name, fields in parser.structs:
        code += f"{name} :: struct {{ "
        for fname, ftype in fields:
            otype = "f32" if ftype == "float" else ftype
            code += f"{fname}: {otype}, "
        code += "}\n\n"

    # Tables (Defs + Pack)
    for name, fields in parser.tables:
        # 1. Definition
        code += f"{name} :: struct {{ "
        for fname, ftype in fields:
            otype = ftype
            if ftype == "int": otype = "i32"
            elif ftype == "float": otype = "f32"
            elif ftype == "bool": otype = "bool"
            elif ftype == "Vec2": otype = "Vec2"
            elif ftype == "[Enemy]": otype = "[dynamic]Enemy" 
            code += f"{fname}: {otype}, "
        code += "}\n\n"

        # 2. Pack Procedure
        code += f"pack_{name} :: proc(b: ^fb.Builder, o: {name}) -> fb.Offset {{\n"
        
        # Pre-process fields (Vectors first)
        for fname, ftype in fields:
            if ftype == "[Enemy]":
                code += f"    vec_{fname}: fb.Offset = 0\n"
                code += f"    if len(o.{fname}) > 0 {{\n"
                code += f"        offsets := make([dynamic]fb.Offset, len(o.{fname}), context.temp_allocator)\n"
                code += f"        for e, i in o.{fname} {{ offsets[i] = pack_Enemy(b, e) }}\n"
                code += f"        fb.start_vector(b, 4, len(o.{fname}), 4)\n"
                code += f"        for i := len(offsets)-1; i >= 0; i -= 1 {{ fb.prepend_offset(b, offsets[i]) }}\n"
                code += f"        vec_{fname} = fb.end_vector(b, len(o.{fname}))\n"
                code += f"    }}\n"

        field_count = len(fields)
        code += f"    fb.start_table(b, {field_count})\n"
        
        for idx, (fname, ftype) in enumerate(fields):
            if ftype == "int":
                code += f"    fb.prepend_int32_slot(b, {idx}, o.{fname}, 0)\n"
            elif ftype == "float":
                code += f"    fb.prepend_float32_slot(b, {idx}, o.{fname}, 0.0)\n"
            elif ftype == "bool":
                code += f"    fb.prepend_bool_slot(b, {idx}, o.{fname}, false)\n"
            elif ftype == "Vec2": # Struct
                code += f"    fb.prepend_struct_slot(b, {idx}, o.{fname})\n"
            elif ftype == "[Enemy]":
                code += f"    if vec_{fname} != 0 {{ fb.prepend_offset_slot(b, {idx}, vec_{fname}) }}\n"
                
        code += f"    return fb.end_table(b)\n"
        code += "}\n\n"

    with open(f"{ODIN_OUT_DIR}/game_state.odin", "w") as f: f.write(code)
    print("Generated Odin bindings with Pack procedures.")

def main():
    schema = SCHEMA_DIR / "GameState.fbs"
    if not schema.exists(): return print(f"No schema found at {schema}")
    
    # Ensure dirs
    for d in [UE_GAME_DIR, ODIN_OUT_DIR]:
        if not os.path.exists(d): os.makedirs(d)

    run_flatc(schema)
    
    parser = SchemaParser(schema.read_text())
    gen_ue_wrappers(parser, parser.tables)
    gen_odin_code(parser)

if __name__ == "__main__":
    main()
