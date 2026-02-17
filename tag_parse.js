import fs from "fs";
import { execSync } from "child_process";
import { PrismaClient } from "@prisma/client";
import keccak256 from "keccak256";
import path from "path";

const prisma = new PrismaClient();

// Function to compute the 4-byte selector using keccak256
function computeSelector(signature) {
  return "0x" + keccak256(signature).toString("hex").slice(0, 8);
}

// Parse source file for @desc and @tag comments
function parseSourceFile(filePath) {
  try {
    // Create a temporary flattened file to parse
    const tempFile = `temp_${path.basename(filePath)}`;
    execSync(`forge flatten ${filePath} > ${tempFile}`);

    const content = fs.readFileSync(tempFile, "utf8");
    console.log(`Read ${content.length} bytes from flattened file ${tempFile}`);

    // Debug: Check if file contains some expected content
    if (content.includes("function")) {
      console.log("File contains function declarations");
    } else {
      console.log("WARNING: No function declarations found in the file!");
    }

    // Extract all struct and enum definitions from the flattened file
    const typeDefinitions = extractStructDefinitions(content);
    console.log(
      `Found ${Object.keys(typeDefinitions.structs).length} struct definitions and ${Object.keys(typeDefinitions.enums).length} enum definitions`,
    );

    fs.unlinkSync(tempFile); // Clean up temp file

    const functionInfos = [];

    // Use a more reliable regex to find function declarations with their surrounding comments
    const functionRegex =
      /\/\/\s*@(?:desc|tag)[^\n]*(?:\n\s*\/\/[^\n]*)*\n\s*function\s+(\w+)\s*\(([^)]*)\)(?:\s+\w+)*(?:\s+returns\s*\([^)]*\))?\s*(?:virtual)?(?:\s*\{|;)/g;

    let match;
    while ((match = functionRegex.exec(content)) !== null) {
      const functionBlock = match[0];
      const functionName = match[1];
      const paramsRaw = match[2].trim();

      console.log(`Found function: ${functionName}`);

      // Extract comments from the function block
      const commentLines = [];
      const lines = functionBlock.split("\n");
      for (const line of lines) {
        const trimmedLine = line.trim();
        if (trimmedLine.startsWith("//")) {
          commentLines.push(trimmedLine);
        }
      }

      // Parse parameters to get the function signature
      const params = [];
      if (paramsRaw) {
        // Split by commas, handling nested parentheses
        const paramsList = splitParams(paramsRaw);

        for (const param of paramsList) {
          // Extract the type, handling custom types
          const paramType = extractParameterType(param.trim());
          // Resolve custom types to tuples
          const resolvedType = resolveType(paramType, typeDefinitions);
          params.push(resolvedType);
        }
      }

      // Create function signature
      const signature = `${functionName}(${params.join(",")})`;

      // Parse comments for @desc and @tag
      let description = "";
      const tags = [];

      for (const line of commentLines) {
        const descMatch = /\/\/\s*@desc\s+(.*)/.exec(line);
        if (descMatch) {
          description = descMatch[1].trim();
          continue;
        }

        const tagMatch = /\/\/\s*@tag\s+(\w+):([^:]+)(?::(.*))?/.exec(line);
        if (tagMatch) {
          tags.push({
            title: tagMatch[1],
            type: tagMatch[2].trim(),
            description: tagMatch[3] ? tagMatch[3].trim() : "",
          });
        }
      }

      // Only add functions with descriptions or tags
      if (description || tags.length > 0) {
        functionInfos.push({
          name: functionName,
          signature,
          selector: computeSelector(signature),
          description,
          tags,
        });
      }
    }

    console.log(`Found ${functionInfos.length} documented functions`);

    // If no functions found, try a more lenient approach as a fallback
    if (functionInfos.length === 0) {
      console.log("Trying alternative parsing method...");
      const commentRegex =
        /\/\/\s*@(?:desc|tag)[^\n]*(?:\n\s*\/\/[^\n]*)*\n\s*function\s+(\w+)/g;

      while ((match = commentRegex.exec(content)) !== null) {
        const functionName = match[1];
        console.log(`Found function by alternative method: ${functionName}`);

        // Extract the full function declaration
        const startIndex = match.index;
        const functionStart = content.indexOf(
          `function ${functionName}`,
          startIndex,
        );
        const openParenIndex = content.indexOf("(", functionStart);
        const closeParenIndex = findMatchingClosingParenthesis(
          content,
          openParenIndex,
        );

        if (closeParenIndex > openParenIndex) {
          const paramsRaw = content
            .substring(openParenIndex + 1, closeParenIndex)
            .trim();

          // Extract comments before the function
          const commentBlock = content.substring(startIndex, functionStart);
          const commentLines = commentBlock
            .split("\n")
            .map((line) => line.trim())
            .filter((line) => line.startsWith("//"));

          // Parse parameters, handling custom types
          const paramsList = splitParams(paramsRaw);
          const params = [];

          for (const param of paramsList) {
            if (param.trim() === "") continue;
            const paramType = extractParameterType(param.trim());
            const resolvedType = resolveType(paramType, typeDefinitions);
            params.push(resolvedType);
          }

          // Create function signature
          const signature = `${functionName}(${params.join(",")})`;

          // Parse comments
          let description = "";
          const tags = [];

          for (const line of commentLines) {
            const descMatch = /\/\/\s*@desc\s+(.*)/.exec(line);
            if (descMatch) {
              description = descMatch[1].trim();
              continue;
            }

            const tagMatch = /\/\/\s*@tag\s+(\w+):([^:]+)(?::(.*))?/.exec(line);
            if (tagMatch) {
              tags.push({
                title: tagMatch[1],
                type: tagMatch[2].trim(),
                description: tagMatch[3] ? tagMatch[3].trim() : "",
              });
            }
          }

          // Only add functions with descriptions or tags
          if (description || tags.length > 0) {
            functionInfos.push({
              name: functionName,
              signature,
              selector: computeSelector(signature),
              description,
              tags,
            });
          }
        }
      }

      console.log(
        `Found ${functionInfos.length} documented functions after alternative parsing`,
      );
    }

    return functionInfos;
  } catch (error) {
    console.error(red(`Error parsing source file ${filePath}: ${error}`));
    console.error(error.stack);
    return [];
  }
}

// Helper function to extract struct definitions from the file
function extractStructDefinitions(content) {
  const definitions = {};
  const enumDefinitions = {}; // Add enum definitions storage

  // First, extract contract and library declarations that might contain structs
  const contractsAndLibraries = [];
  const contractRegex =
    /(contract|library|interface)\s+(\w+)(?:\s+is\s+[^{]+)?\s*{/g;
  let contractMatch;

  while ((contractMatch = contractRegex.exec(content)) !== null) {
    const contractType = contractMatch[1];
    const contractName = contractMatch[2];
    const startIndex = contractMatch.index;

    // Find the matching closing brace
    const contractBody = extractBalancedSection(
      content,
      startIndex + content.substring(startIndex).indexOf("{"),
    );

    contractsAndLibraries.push({
      type: contractType,
      name: contractName,
      body: contractBody,
    });
  }

  // Process each contract/library to find structs and enums
  for (const container of contractsAndLibraries) {
    // Extract structs
    const structRegex = /struct\s+(\w+)\s*{([^}]*)}/g;
    let structMatch;

    while ((structMatch = structRegex.exec(container.body)) !== null) {
      const structName = structMatch[1];
      const structBody = structMatch[2];

      // Parse the struct fields
      const fields = parseStructFields(structBody);

      // Add to definitions with the container as namespace
      definitions[`${container.name}.${structName}`] = fields;

      // Also add without namespace (for common structs)
      definitions[structName] = fields;
    }

    // Extract enums
    const enumRegex = /enum\s+(\w+)\s*{([^}]*)}/g;
    let enumMatch;

    while ((enumMatch = enumRegex.exec(container.body)) !== null) {
      const enumName = enumMatch[1];

      // Add to enum definitions with the container as namespace
      enumDefinitions[`${container.name}.${enumName}`] = "uint8";

      // Also add without namespace
      enumDefinitions[enumName] = "uint8";
    }
  }

  // Also find top-level structs
  const topLevelStructRegex = /struct\s+(\w+)\s*{([^}]*)}/g;
  let topLevelMatch;

  while ((topLevelMatch = topLevelStructRegex.exec(content)) !== null) {
    // Skip if this struct is within a contract (already processed)
    let isInContract = false;
    for (const container of contractsAndLibraries) {
      if (container.body.includes(topLevelMatch[0])) {
        isInContract = true;
        break;
      }
    }

    if (!isInContract) {
      const structName = topLevelMatch[1];
      const structBody = topLevelMatch[2];

      // Parse the struct fields
      const fields = parseStructFields(structBody);

      // Add to definitions
      definitions[structName] = fields;
    }
  }

  // Also find top-level enums
  const topLevelEnumRegex = /enum\s+(\w+)\s*{([^}]*)}/g;
  let topLevelEnumMatch;

  while ((topLevelEnumMatch = topLevelEnumRegex.exec(content)) !== null) {
    // Skip if this enum is within a contract (already processed)
    let isInContract = false;
    for (const container of contractsAndLibraries) {
      if (container.body.includes(topLevelEnumMatch[0])) {
        isInContract = true;
        break;
      }
    }

    if (!isInContract) {
      const enumName = topLevelEnumMatch[1];

      // Add to enum definitions
      enumDefinitions[enumName] = "uint8";
    }
  }

  // Combine struct and enum definitions
  return {
    structs: definitions,
    enums: enumDefinitions,
  };
}

// Parse struct fields into type information
function parseStructFields(structBody) {
  const fields = [];

  // Split by semicolons and filter out empty lines
  const lines = structBody
    .split(";")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("//"));

  for (const line of lines) {
    // Split by whitespace and get the type (first element)
    const parts = line.trim().split(/\s+/);
    if (parts.length >= 2) {
      const type = parts[0];
      fields.push(type);
    }
  }

  return fields;
}

// Helper function to extract a balanced section of text (handling nested braces)
function extractBalancedSection(text, startIndex) {
  let depth = 0;
  let i = startIndex;

  for (; i < text.length; i++) {
    if (text[i] === "{") {
      depth++;
    } else if (text[i] === "}") {
      depth--;
      if (depth === 0) {
        break;
      }
    }
  }

  return text.substring(startIndex, i + 1);
}

// Helper function to split parameters by commas, respecting nested parentheses and brackets
function splitParams(paramsStr) {
  const params = [];
  let currentParam = "";
  let depth = 0;

  for (let i = 0; i < paramsStr.length; i++) {
    const char = paramsStr[i];

    if (
      (char === "(" || char === "[") &&
      (i === 0 || paramsStr[i - 1] !== "\\")
    ) {
      depth++;
      currentParam += char;
    } else if (
      (char === ")" || char === "]") &&
      (i === 0 || paramsStr[i - 1] !== "\\")
    ) {
      depth--;
      currentParam += char;
    } else if (char === "," && depth === 0) {
      params.push(currentParam.trim());
      currentParam = "";
    } else {
      currentParam += char;
    }
  }

  if (currentParam.trim()) {
    params.push(currentParam.trim());
  }

  return params;
}

// Helper function to resolve a type, converting custom types to their tuple representation
function resolveType(type, typeDefinitions) {
  const { structs, enums } = typeDefinitions;

  // Strip any namespace prefix (e.g., "DecoderCustomTypes.")
  const cleanType = type.includes(".")
    ? type.substring(type.lastIndexOf(".") + 1)
    : type;

  // Handle array types
  const isArray = cleanType.includes("[");
  const baseType = isArray
    ? cleanType.substring(0, cleanType.indexOf("["))
    : cleanType;
  const arraySuffix = isArray
    ? cleanType.substring(cleanType.indexOf("["))
    : "";

  // Check if this is an enum type
  if (enums[baseType]) {
    return `uint8${arraySuffix}`;
  }

  // Check if the fully qualified enum name is in the definitions
  if (type.includes(".") && enums[type]) {
    return `uint8${arraySuffix}`;
  }

  // Handle contract and interface types by converting them to address
  if (
    baseType === "ERC20" ||
    baseType === "IERC20" ||
    baseType.endsWith("_1")
  ) {
    return `address${arraySuffix}`;
  }

  // Check if this is a struct type that needs to be expanded
  if (structs[baseType]) {
    const fieldTypes = structs[baseType];

    // Recursively resolve each field type
    const resolvedFields = fieldTypes.map((fieldType) =>
      resolveType(fieldType, typeDefinitions),
    );

    // Return as a tuple with the array suffix if applicable
    return `(${resolvedFields.join(",")})${arraySuffix}`;
  }

  // Also check if the fully qualified struct name is in the definitions
  if (type.includes(".") && structs[type]) {
    const fieldTypes = structs[type];

    // Recursively resolve each field type
    const resolvedFields = fieldTypes.map((fieldType) =>
      resolveType(fieldType, typeDefinitions),
    );

    // Return as a tuple with the array suffix if applicable
    return `(${resolvedFields.join(",")})${arraySuffix}`;
  }

  // If it's not a struct/enum or we don't have its definition, return as is
  return cleanType;
}

// Helper function to find matching closing parenthesis
function findMatchingClosingParenthesis(str, openIndex) {
  let depth = 1;
  for (let i = openIndex + 1; i < str.length; i++) {
    if (str[i] === "(") {
      depth++;
    } else if (str[i] === ")") {
      depth--;
      if (depth === 0) {
        return i;
      }
    }
  }
  return -1; // No matching parenthesis found
}

// Helper function to extract just the type from a parameter declaration
function extractParameterType(param) {
  param = param.trim();
  if (!param) return "";

  // Check for function type declarations
  if (param.includes(" function ")) {
    return "function";
  }

  // Handle named parameters (extract only the type part)
  const parts = param.split(/\s+/);

  // If we have multiple parts, this might be a named parameter
  if (parts.length > 1) {
    // Check if the first part is a type (handle mappings, arrays, etc.)
    if (
      parts[0].includes("(") ||
      parts[0].includes("[") ||
      parts[0].includes("mapping")
    ) {
      // This is a complex type
      // Find where the type ends and the name begins
      let typeEnd = param.lastIndexOf(" ");
      if (typeEnd !== -1) {
        return param
          .substring(0, typeEnd)
          .trim()
          .replace(/\s+memory\b|\s+calldata\b|\s+storage\b/g, ""); // Remove storage modifiers
      }
    } else {
      // Simple type - just return the first part
      return parts[0];
    }
  }

  // Handle complex types or unnamed parameters
  return param.replace(/\s+memory\b|\s+calldata\b|\s+storage\b/g, ""); // Remove storage modifiers
}

// Process contract ABI and source file to extract function information
async function processContract(filePath, shouldPost = false) {
  try {
    // Extract docs from source file
    const functionInfos = parseSourceFile(filePath);

    if (shouldPost && functionInfos.length > 0) {
      return await postToDatabase(functionInfos);
    } else if (functionInfos.length > 0) {
      // Print output when not posting
      console.log(`\nProcessed ${filePath}:`);
      for (const func of functionInfos) {
        console.log(`  ${func.signature} => ${func.selector}`);
        console.log(`    Description: ${func.description}`);
        if (func.tags.length > 0) {
          console.log("    Parameters:");
          func.tags.forEach((param) => {
            console.log(
              `      ${param.title}: ${param.type} - ${param.description}`,
            );
          });
        }
        console.log("");
      }
    }

    return functionInfos.length;
  } catch (error) {
    console.error(red(`Error processing contract ${filePath}: ${error}`));
    return 0;
  }
}

// Add a new function to generate a hash-based ID from function data
function generateRecordId(data) {
  // Create a string that combines core function data (excluding tags since they're in separate table)
  const contentToHash = `${data.signature}|${data.description}`;

  // Generate a hash using keccak256 (already imported for selector calculation)
  return "0x" + keccak256(contentToHash).toString("hex").slice(0, 24);
}

// Update the checkExistingRecords function to use Prisma
async function checkExistingRecords(functionsData) {
  const existingIds = [];

  for (const data of functionsData) {
    // Generate the ID for this function data
    data.id = generateRecordId(data);

    try {
      // Check if this ID already exists
      const existingRecord = await prisma.decoderSelector.findUnique({
        where: { id: data.id },
      });
      if (existingRecord) {
        console.log(`Found existing record with ID: ${data.id}`);
        existingIds.push(data.id);
      }
    } catch (error) {
      // Not found, which is fine
      console.error(`Error checking existing record: ${error.message}`);
    }
  }

  return existingIds;
}

// Update the postToDatabase function to use Prisma
async function postToDatabase(functionsData) {
  try {
    let successCount = 0;

    // First, generate IDs and check for existing records
    for (const data of functionsData) {
      data.id = generateRecordId(data);
    }

    const existingIds = await checkExistingRecords(functionsData);

    // Process each record individually
    for (const data of functionsData) {
      try {
        // Skip if this ID already exists
        if (existingIds.includes(data.id)) {
          console.log(
            `Skipping existing record with ID: ${data.id} (${data.signature})`,
          );
          continue;
        }

        // Create the new record with our custom ID and related tags
        await prisma.decoderSelector.create({
          data: {
            id: data.id,
            selector: data.selector,
            description: data.description,
            signature: data.signature,
            tags: {
              create: data.tags.map((tag) => ({
                title: tag.title,
                type: tag.type,
                description: tag.description,
              })),
            },
          },
        });

        console.log(
          `Created record for: ${data.signature} => ${data.selector} (ID: ${data.id})`,
        );
        successCount++;
      } catch (error) {
        // Log error but continue with other records
        console.error(
          red(`Error processing function ${data.signature}: ${error.message}`),
        );
      }
    }

    return successCount;
  } catch (error) {
    console.error(red(`Error posting to database: ${error}`));
    return 0;
  } finally {
    // Close the Prisma connection
  }
}

// Function to find all Solidity files in the DecodersAndSanitizers directory
function findAllDecoderFiles(includeSubdirs = false) {
  const baseDir = "src/base/DecodersAndSanitizers";

  try {
    // Use -maxdepth 1 to limit search to only the specified directory
    const depthOption = includeSubdirs ? "" : "-maxdepth 1";
    const files = execSync(`find ${baseDir} ${depthOption} -name "*.sol"`, {
      encoding: "utf8",
    })
      .trim()
      .split("\n")
      .filter((file) => file); // Remove any empty strings

    return files;
  } catch (error) {
    console.error(red(`Error finding Solidity files: ${error.message}`));
    return [];
  }
}

// Helper function to print text in color
function colorText(text, colorCode) {
  return `\x1b[${colorCode}m${text}\x1b[0m`;
}

// Convenience function for red text (for errors)
function red(text) {
  return colorText(text, 31);
}

async function main() {
  // Get command line arguments
  const args = process.argv.slice(2);

  // Check for flags
  const postIndex = args.indexOf("--post");
  const shouldPost = postIndex !== -1;
  if (postIndex !== -1) {
    args.splice(postIndex, 1);
  }

  const allDecodersIndex = args.indexOf("--all-decoders");
  const processAllDecoders = allDecodersIndex !== -1;
  if (allDecodersIndex !== -1) {
    args.splice(allDecodersIndex, 1);
  }

  // Add subdirectory option
  const includeSubdirsIndex = args.indexOf("--include-subdirs");
  const includeSubdirs = includeSubdirsIndex !== -1;
  if (includeSubdirsIndex !== -1) {
    args.splice(includeSubdirsIndex, 1);
  }

  let filesToProcess = [];

  if (processAllDecoders) {
    // Process all decoder files
    filesToProcess = findAllDecoderFiles(includeSubdirs);
  } else if (args.length > 0) {
    // Process specific files provided as arguments
    filesToProcess = args;
  } else {
    console.error(
      red(
        "Error: Please provide file paths as arguments or use --all-decoders flag",
      ),
    );
    console.error(
      red(
        "Usage: node tag_parse.js [file_paths...] [--post] [--all-decoders] [--include-subdirs]",
      ),
    );
    console.error(
      red("  --post: Post the data to PostgreSQL database (otherwise dry run)"),
    );
    console.error(
      red(
        "  --all-decoders: Process all files in src/base/DecodersAndSanitizers",
      ),
    );
    console.error(
      red(
        "  --include-subdirs: Include files in subdirectories when using --all-decoders",
      ),
    );
    process.exit(1);
  }

  // Process each file
  let totalFunctions = 0;
  for (const file of filesToProcess) {
    if (!fs.existsSync(file)) {
      console.error(red(`Error: File not found: ${file}`));
      continue;
    }

    const functionCount = await processContract(file, shouldPost);
    totalFunctions += functionCount;
  }

  // Add summary output
  console.log(`\nTotal functions processed: ${totalFunctions}`);
  if (shouldPost) {
    console.log(`Data has been posted to PostgreSQL database`);
  } else {
    console.log(
      "This was a dry run. Use --post to upload data to the database.",
    );
  }

  await prisma.$disconnect();
}

// Execute the main function
main().catch(async (error) => {
  console.error(red(`Unhandled error: ${error}`));
  await prisma.$disconnect();
  process.exit(1);
});
