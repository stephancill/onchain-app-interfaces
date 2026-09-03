import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig, type Plugin } from "vite";

const skillName = "onchain-app-interfaces";
const skillDirectory = fileURLToPath(
  new URL(`../skills/${skillName}/`, import.meta.url),
);

function skillFiles(directory = skillDirectory): string[] {
  return readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.name !== "__pycache__")
    .flatMap((entry) => {
      const path = join(directory, entry.name);
      return entry.isDirectory() ? skillFiles(path) : [path];
    })
    .sort();
}

function skillCatalog(): Plugin {
  return {
    name: "onchain-app-interface-skill-catalog",
    apply: "build",
    generateBundle() {
      const files = skillFiles();
      const hash = createHash("sha256");
      const publishedFiles = files.map((path) => {
        const source = readFileSync(path);
        const sourceName = relative(skillDirectory, path).replaceAll("\\", "/");
        const publishedName =
          sourceName === "SKILL.md" ? `${skillName}.md` : sourceName;
        hash.update(publishedName);
        hash.update(source);
        this.emitFile({
          type: "asset",
          fileName: `.well-known/skills/${skillName}/${publishedName}`,
          source,
        });
        return publishedName;
      });
      this.emitFile({
        type: "asset",
        fileName: ".well-known/skills/index.json",
        source: JSON.stringify(
          {
            skills: [
              {
                name: skillName,
                version: hash.digest("hex").slice(0, 16),
                files: publishedFiles,
              },
            ],
          },
          null,
          2,
        ),
      });
    },
  };
}

export default defineConfig({
  plugins: [tailwindcss(), react(), skillCatalog()],
  server: { fs: { allow: [".."] } },
});
