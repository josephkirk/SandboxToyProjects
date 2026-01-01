import os
import subprocess
import re
from pathlib import Path

# Configuration
SCRIPT_DIR = Path(__file__).parent.resolve()
FLATC_PATH = SCRIPT_DIR / r"..\..\thirdparties\Windows.flatc.binary\flatc.exe"
SCHEMA_DIR = SCRIPT_DIR / r"..\schemas"
UE_PUBLIC_DIR = SCRIPT_DIR / r"..\renderer\OdinRender\Plugins\OdinRenderClient\Source\OdinRenderClient\Public\Generated"
UE_PRIVATE_DIR = SCRIPT_DIR / r"..\renderer\OdinRender\Plugins\OdinRenderClient\Source\OdinRenderClient\Private\Generated"
ODIN_OUT_DIR = SCRIPT_DIR / r"..\game\generated"

def run_flatc(schema_file):
    # Generate C++ for Unreal
    cmd = [
        str(FLATC_PATH),
        "--cpp",
        "--cpp-std", "c++17",
        "--gen-object-api",
        "--filename-suffix", "_flatbuffer",
        "-o", str(UE_PUBLIC_DIR),
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
    cpp = """#include "Generated/GameStateWrappers.h"
"""

    for name, fields in parser.tables:
        wrapper_name = f"U{name}Wrapper"
        
        header += f"""UCLASS(BlueprintType)
class {wrapper_name} : public UObject
{{
    GENERATED_BODY()
public:
    const VS::Schema::{name}* Buffer = nullptr;
    void Init(const VS::Schema::{name}* InBuffer) {{ Buffer = InBuffer; }}
"""
        for fname, ftype in fields:
            ue_type = "int32"
            ue_ret = f"Buffer->{fname}()"
            
            # Type mapping
            if ftype == "int": ue_type = "int32"
            elif ftype == "float": ue_type = "float"
            elif ftype == "bool": ue_type = "bool"
            elif "Vec2" in ftype: # Struct needs special handling
                ue_type = "FVector2D"
                ue_ret = f"FVector2D(Buffer->{fname}()->x(), Buffer->{fname}()->y())"
            elif ftype == "Player" or ftype == "Enemy": # Tables -> Wrappers
                ue_type = f"U{ftype}Wrapper*"
                # For tables, we need to Construct/Init a new wrapper. 
                # Optimization: Cache? For now, create new (GC handles it).
                ue_ret = f"NewObject<U{ftype}Wrapper>(const_cast<UObject*>(reinterpret_cast<const UObject*>(this)));"
                ue_ret += f" result->Init(Buffer->{fname}()); return result" 
                # Wait, this is getting complex for a one-liner return. We need body expansion.
            elif "[" in ftype: continue 
            
            header += f"""    UFUNCTION(BlueprintPure, Category = "Odin|{name}")
    {ue_type} Get{fname.title()}() const {{
        if (!Buffer) return {{}};
"""
            if ftype == "Player" or ftype == "Enemy":
                header += f"""        U{ftype}Wrapper* Wrapper = NewObject<U{ftype}Wrapper>(const_cast<UObject*>(reinterpret_cast<const UObject*>(this)));
        Wrapper->Init(Buffer->{fname}());
        return Wrapper;
    }}
"""
            else:
                header += f"        return {ue_ret};\n    }}\n"
        header += "};\n\n"

    with open(f"{UE_PUBLIC_DIR}/GameStateWrappers.h", "w") as f: f.write(header)
    with open(f"{UE_PRIVATE_DIR}/GameStateWrappers.cpp", "w") as f: f.write(cpp)
    print("Generated Unreal Wrappers.")

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
    for d in [UE_PUBLIC_DIR, UE_PRIVATE_DIR, ODIN_OUT_DIR]:
        if not os.path.exists(d): os.makedirs(d)

    run_flatc(schema)
    
    parser = SchemaParser(schema.read_text())
    gen_ue_wrappers(parser, parser.tables)
    gen_odin_code(parser)

if __name__ == "__main__":
    main()
