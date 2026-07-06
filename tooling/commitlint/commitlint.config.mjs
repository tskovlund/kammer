export default {
  extends: ["@commitlint/config-conventional"],
  rules: {
    // Keep subjects readable in `git log --oneline`.
    "header-max-length": [2, "always", 100],
  },
};
