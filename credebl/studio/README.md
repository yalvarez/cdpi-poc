

## 🚀 Quick start

This Studio UI is part of the CREDEBL stack. For most users, you do **not** need to run this separately — it is launched automatically as part of the main platform deployment.

If you want to develop or test the UI locally:

1. Clone this repository or download the ZIP file
2. Make sure that you have **Node.js** and NPM, PNPM or Yarn installed
3. Install the project dependencies from the `package.json` file:

```sh
pnpm install
# or
npm install
# or
yarn
```

_PNPM is the package manager of choice for illustration, but you can use what you want._

4. Launch the Next.js local development server on `localhost:3000` by running:

```sh
pnpm run dev
```

You can also build the project and get the distribution files inside the `.next/` folder by running:

```sh
pnpm run build
```


---

## Platform deployment

For full platform setup, see the root `README.md` and use the automated scripts (`scripts/init-credebl.sh`, `scripts/setup-vps.sh`).

---

## Contributing

Pull requests are welcome! Please read our [contributions guide](https://github.com/credebl/platform/blob/main/CONTRIBUTING.md) and submit your PRs. We enforce [developer certificate of origin](https://developercertificate.org/) (DCO) commit signing — [guidance](https://github.com/apps/dco) on this is available. We also welcome issues submitted about problems you encounter in using CREDEBL.

## License

[Apache License Version 2.0](https://github.com/credebl/platform/blob/main/LICENSE)
