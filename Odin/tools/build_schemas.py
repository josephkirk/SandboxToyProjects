import os
import subprocess
import re
import sys
from pathlib import Path

# Configuration
SCRIPT_DIR = Path(__file__).parent.resolve()
FLATC_PATH = SCRIPT_DIR / r"..\..\thirdparties\Windows.flatc.binary\flatc.exe"
SCHEMA_DIR = SCRIPT_DIR / r"..\schemas"

# Output directories (Plugin for generic, Game Module for game-specific wrappers)
UE_PLUGIN_DIR = SCRIPT_DIR / r"..\renderer\OdinRender\Plugins\OdinRenderClient\Source\OdinRenderClient\Public\Generated"
UE_GAME_DIR = SCRIPT_DIR / r"..\renderer\OdinRender\Source\OdinRender\Generated"
ODIN_OUT_DIR = SCRIPT_DIR / r"..\game\generated"

# API macros
PLUGIN_API = "ODINRENDERCLIENT_API"
GAME_API = "ODINRENDER_API"

class SchemaParser:
    """Parses FlatBuffer schema files and categorizes types."""
    
    def __init__(self, content, namespace=""):
        self.content = content
        self.namespace = namespace
        self.root_type = None
        self.tables = []
        self.structs = []
        self.enums = []
        self.parse()
    
    def parse(self):
        # Remove comments
        text = re.sub(r"//.*", "", self.content)
        
        # Parse namespace
        ns_match = re.search(r"namespace\s+([\w\.]+);", text)
        if ns_match:
            self.namespace = ns_match.group(1)
        
        # Parse root_type
        root_match = re.search(r"root_type\s+(\w+);", text)
        if root_match:
            self.root_type = root_match.group(1)
        
        # Parse enums
        for match in re.finditer(r"enum\s+(\w+)\s*:\s*\w+\s*{([^}]*)}", text, re.MULTILINE | re.DOTALL):
            name = match.group(1)
            body = match.group(2)
            values = self.parse_enum_values(body)
            self.enums.append((name, values))
        
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
    
    def parse_enum_values(self, body):
        values = []
        for match in re.finditer(r"(\w+)\s*=\s*(\d+)", body):
            values.append((match.group(1), int(match.group(2))))
        return values
    
    def get_struct_names(self):
        return set(name for name, _ in self.structs)
    
    def get_table_names(self):
        return set(name for name, _ in self.tables)
    
    def validate_no_table_refs(self):
        """Validate that tables do not reference other tables."""
        table_names = self.get_table_names()
        errors = []
        
        for table_name, fields in self.tables:
            for field_name, field_type in fields:
                # Check for array of tables
                if field_type.startswith("[") and field_type.endswith("]"):
                    inner = field_type[1:-1]
                    if inner in table_names:
                        # Arrays of tables are allowed (pooled)
                        continue
                # Check for direct table reference
                if field_type in table_names:
                    errors.append(f"table '{table_name}' cannot reference table '{field_type}' directly (field: {field_name})")
        
        if errors:
            for err in errors:
                print(f"[ERROR] {err}", file=sys.stderr)
            return False
        return True


def map_to_ue_type(fbs_type, struct_names, table_names):
    """Map FlatBuffer type to Unreal type."""
    # Primitive types
    type_map = {
        "int": "int32",
        "float": "float",
        "bool": "bool",
        "string": "FString",
        "int8": "int8",
        "int16": "int16",
        "int32": "int32",
        "int64": "int64",
        "uint8": "uint8",
        "uint16": "uint16",
        "uint32": "uint32",
        "uint64": "uint64",
        "float32": "float",
        "float64": "double",
    }
    
    # Check for array
    if fbs_type.startswith("[") and fbs_type.endswith("]"):
        inner = fbs_type[1:-1]
        inner_ue = map_to_ue_type(inner, struct_names, table_names)
        return f"TArray<{inner_ue}>"
    
    # Check primitives
    if fbs_type in type_map:
        return type_map[fbs_type]
    
    # Struct (Vec2-like)
    if fbs_type in struct_names:
        if "Vec2" in fbs_type:
            return "FVector2D"
        elif "Vec3" in fbs_type:
            return "FVector"
        else:
            return f"F{fbs_type}"  # USTRUCT
    
    # Table -> UObject pointer
    if fbs_type in table_names:
        return f"UOdin{fbs_type}*"
    
    # Enum -> int32
    return "int32"


def run_flatc(schema_file, output_dir):
    """Run flatc to generate C++ headers."""
    cmd = [
        str(FLATC_PATH),
        "--cpp",
        "--cpp-std", "c++17",
        "--gen-object-api",
        "--filename-suffix", "_flatbuffer",
        "-o", str(output_dir),
        str(schema_file)
    ]
    print(f"Running flatc: {' '.join(cmd)}")
    subprocess.check_call(cmd)


def gen_ustruct_code(parser, output_dir, api_macro, schema_basename):
    """Generate USTRUCT wrappers for FlatBuffer structs only."""
    header = f"""#pragma once
#include "CoreMinimal.h"
#include "{schema_basename}_flatbuffer.h"
#include "{schema_basename}Structs.generated.h"

"""
    cpp = f"""#include "{schema_basename}Structs.h"
"""

    struct_names = parser.get_struct_names()
    table_names = parser.get_table_names()
    
    for name, fields in parser.structs:
        wrapper_name = f"F{name}"
        
        header += f"""USTRUCT(BlueprintType)
struct {api_macro} {wrapper_name} {{
    GENERATED_BODY()

"""
        for fname, ftype in fields:
            ue_type = map_to_ue_type(ftype, struct_names, table_names)
            prop_name = fname.title().replace("_", "")
            header += f"    UPROPERTY(BlueprintReadWrite, Category = \"Odin\")\n"
            header += f"    {ue_type} {prop_name};\n\n"
        
        header += "};\n\n"
    
    with open(f"{output_dir}/{schema_basename}Structs.h", "w") as f:
        f.write(header)
    with open(f"{output_dir}/{schema_basename}Structs.cpp", "w") as f:
        f.write(cpp)
    
    print(f"Generated USTRUCTs for {len(parser.structs)} structs.")


def gen_uobject_code(parser, output_dir, api_macro, schema_basename, fb_namespace):
    """Generate UObject and AActor wrappers for FlatBuffer tables."""
    
    struct_names = parser.get_struct_names()
    table_names = parser.get_table_names()
    root_type = parser.root_type
    
    header = f"""#pragma once
#include "CoreMinimal.h"
#include "OdinDataObject.h"
#include "OdinDataActor.h"
#include "{schema_basename}_flatbuffer.h"
#include "{schema_basename}Structs.h"
#include "{schema_basename}Objects.generated.h"

"""
    cpp = f"""#include "{schema_basename}Objects.h"
#include "flatbuffers/flatbuffers.h"

"""
    
    for table_name, fields in parser.tables:
        uobject_name = f"UOdin{table_name}"
        actor_name = f"AOdin{table_name}Actor"
        is_root = (table_name == root_type)
        
        # UObject class
        header += f"""UCLASS(BlueprintType)
class {api_macro} {uobject_name} : public UOdinDataObject {{
    GENERATED_BODY()
public:
"""
        # Properties
        for fname, ftype in fields:
            prop_name = fname.title().replace("_", "")
            
            if ftype in struct_names:
                if "Vec2" in ftype:
                    ue_type = "FVector2D"
                else:
                    ue_type = f"F{ftype}"
            elif ftype.startswith("[") and ftype.endswith("]"):
                inner = ftype[1:-1]
                if inner in table_names:
                    ue_type = "int32"
                    prop_name = f"{prop_name}Count"
                else:
                    ue_type = map_to_ue_type(ftype, struct_names, table_names)
            else:
                ue_type = map_to_ue_type(ftype, struct_names, table_names)
            
            header += f"    UPROPERTY(BlueprintReadWrite, Category = \"Odin|{table_name}\")\n"
            header += f"    {ue_type} {prop_name};\n\n"
        
        # Methods depend on whether this is root type
        if is_root:
            header += f"    virtual void UpdateFromOdinData(const uint8* Buffer, int32 Size) override;\n"
        else:
            # Non-root types get updated from FB table pointer
            header += f"    void UpdateFromFlatBuffer(const {fb_namespace}::{table_name}* InTable);\n"
            header += f"    virtual void UpdateFromOdinData(const uint8* Buffer, int32 Size) override {{ /* Non-root: use UpdateFromFlatBuffer */ }}\n"
        
        header += "};\n\n"
        
        # Actor class
        header += f"""UCLASS()
class {api_macro} {actor_name} : public AOdinDataActor {{
    GENERATED_BODY()
public:
    {actor_name}();
    
    UFUNCTION(BlueprintPure, Category = \"Odin|{table_name}\")
    {uobject_name}* Get{table_name}Data() const {{ return Cast<{uobject_name}>(DataObject); }}
}};

"""
        
        # CPP implementation
        if is_root:
            # Root type: full buffer parsing
            cpp += f"""void {uobject_name}::UpdateFromOdinData(const uint8* Buffer, int32 Size) {{
    if (!Buffer || Size == 0) return;
    
    flatbuffers::Verifier Verifier(Buffer, Size);
    if (!{fb_namespace}::Verify{table_name}Buffer(Verifier)) return;
    
    const {fb_namespace}::{table_name}* Root = {fb_namespace}::Get{table_name}(Buffer);
    if (!Root) return;
    
"""
        else:
            # Non-root type: takes FB table pointer directly
            cpp += f"""void {uobject_name}::UpdateFromFlatBuffer(const {fb_namespace}::{table_name}* Root) {{
    if (!Root) return;
    
"""
        
        # Field updates (same for both)
        for fname, ftype in fields:
            prop_name = fname.title().replace("_", "")
            
            if ftype in ["int", "float", "bool", "int32", "float32"]:
                cpp += f"    {prop_name} = Root->{fname}();\n"
            elif ftype in struct_names:
                if "Vec2" in ftype:
                    cpp += f"    if (Root->{fname}()) {prop_name} = FVector2D(Root->{fname}()->x(), Root->{fname}()->y());\n"
                else:
                    cpp += f"    // Copy struct {ftype} fields\n"
                    cpp += f"    if (Root->{fname}()) {{\n"
                    for sname, sfields in parser.structs:
                        if sname == ftype:
                            for sfname, sftype in sfields:
                                sprop = sfname.title().replace("_", "")
                                cpp += f"        {prop_name}.{sprop} = Root->{fname}()->{sfname}();\n"
                            break
                    cpp += f"    }}\n"
            elif ftype.startswith("[") and ftype.endswith("]"):
                inner = ftype[1:-1]
                if inner in table_names:
                    cpp += f"    {prop_name}Count = Root->{fname}() ? Root->{fname}()->size() : 0;\n"
        
        cpp += "}\n\n"
        
        # Actor constructor
        cpp += f"""{actor_name}::{actor_name}() {{
    DataObject = CreateDefaultSubobject<{uobject_name}>(TEXT("{table_name}Data"));
}}

"""
    
    with open(f"{output_dir}/{schema_basename}Objects.h", "w") as f:
        f.write(header)
    with open(f"{output_dir}/{schema_basename}Objects.cpp", "w") as f:
        f.write(cpp)
    
    print(f"Generated UObjects and Actors for {len(parser.tables)} tables.")


def gen_odin_code(parser, output_dir, schema_basename):
    """Generate Odin bindings (game-specific, minimal changes)."""
    code = f"""package generated

import "core:fmt"
import fb "../flatbuffers"

"""
    # Structs
    for name, fields in parser.structs:
        code += f"{name} :: struct {{ "
        for fname, ftype in fields:
            otype = "f32" if ftype == "float" else ftype
            if otype == "int": otype = "i32"
            code += f"{fname}: {otype}, "
        code += "}\n\n"
    
    # Tables with pack procedures
    for name, fields in parser.tables:
        code += f"{name} :: struct {{ "
        for fname, ftype in fields:
            otype = ftype
            if ftype == "int": otype = "i32"
            elif ftype == "float": otype = "f32"
            elif ftype == "bool": otype = "bool"
            elif ftype.startswith("["): 
                inner = ftype[1:-1]
                otype = f"[dynamic]{inner}"
            code += f"{fname}: {otype}, "
        code += "}\n\n"
        
        # Pack procedure
        code += f"pack_{name} :: proc(b: ^fb.Builder, o: {name}) -> fb.Offset {{\n"
        
        # Pre-process vectors
        for fname, ftype in fields:
            if ftype.startswith("["):
                inner = ftype[1:-1]
                code += f"    vec_{fname}: fb.Offset = 0\n"
                code += f"    if len(o.{fname}) > 0 {{\n"
                code += f"        offsets := make([dynamic]fb.Offset, len(o.{fname}), context.temp_allocator)\n"
                code += f"        for e, i in o.{fname} {{ offsets[i] = pack_{inner}(b, e) }}\n"
                code += f"        fb.start_vector(b, 4, len(o.{fname}), 4)\n"
                code += f"        for i := len(offsets)-1; i >= 0; i -= 1 {{ fb.prepend_offset(b, offsets[i]) }}\n"
                code += f"        vec_{fname} = fb.end_vector(b, len(o.{fname}))\n"
                code += f"    }}\n"
        
        code += f"    fb.start_table(b, {len(fields)})\n"
        
        for idx, (fname, ftype) in enumerate(fields):
            if ftype == "int":
                code += f"    fb.prepend_int32_slot(b, {idx}, o.{fname}, 0)\n"
            elif ftype == "float":
                code += f"    fb.prepend_float32_slot(b, {idx}, o.{fname}, 0.0)\n"
            elif ftype == "bool":
                code += f"    fb.prepend_bool_slot(b, {idx}, o.{fname}, false)\n"
            elif ftype in parser.get_struct_names():
                code += f"    fb.prepend_struct_slot(b, {idx}, o.{fname})\n"
            elif ftype.startswith("["):
                code += f"    if vec_{fname} != 0 {{ fb.prepend_offset_slot(b, {idx}, vec_{fname}) }}\n"
        
        code += f"    return fb.end_table(b)\n"
        code += "}\n\n"
    
    with open(f"{output_dir}/{schema_basename.lower()}.odin", "w") as f:
        f.write(code)
    
    print(f"Generated Odin bindings.")


def main():
    # Find all schema files
    schemas = list(SCHEMA_DIR.glob("*.fbs"))
    if not schemas:
        print(f"No schemas found in {SCHEMA_DIR}")
        return 1
    
    # Ensure output directories
    for d in [UE_PLUGIN_DIR, UE_GAME_DIR, ODIN_OUT_DIR]:
        d.mkdir(parents=True, exist_ok=True)
    
    for schema_path in schemas:
        print(f"\n=== Processing {schema_path.name} ===")
        
        schema_basename = schema_path.stem
        content = schema_path.read_text()
        parser = SchemaParser(content)
        
        # Validate schema
        if not parser.validate_no_table_refs():
            print(f"[SKIP] Schema validation failed for {schema_path.name}")
            continue
        
        # Run flatc for C++ headers
        run_flatc(schema_path, UE_GAME_DIR)
        
        # Generate USTRUCTs (game module)
        gen_ustruct_code(parser, UE_GAME_DIR, GAME_API, schema_basename)
        
        # Generate UObjects + Actors (game module)
        fb_namespace = parser.namespace.replace(".", "::")
        gen_uobject_code(parser, UE_GAME_DIR, GAME_API, schema_basename, fb_namespace)
        
        # Generate Odin code
        gen_odin_code(parser, ODIN_OUT_DIR, schema_basename)
    
    print("\n=== Code generation complete ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
