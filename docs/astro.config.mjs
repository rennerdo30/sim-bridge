import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightThemeGalaxy from 'starlight-theme-galaxy';

export default defineConfig({
  site: 'https://sim-bridge.renner.dev',
  base: '/docs',
  trailingSlash: 'always',
  integrations: [
    starlight({
      title: 'Sim Bridge',
      description: 'Self-hosted, encrypted SMS bridging for phones and desktops.',
      logo: { src: './src/assets/logo.svg' },
      favicon: '/favicon.svg',
      plugins: [starlightThemeGalaxy()],
      // Galaxy's HeaderButton drops aria-label props; retain an accessible toggle.
      components: { ThemeSelect: './src/components/ThemeSelect.astro' },
      customCss: ['./src/styles/custom.css'],
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/rennerdo30/sim-bridge' },
      ],
      editLink: {
        baseUrl: 'https://github.com/rennerdo30/sim-bridge/edit/main/docs/',
      },
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Overview', slug: 'index' },
            { label: 'Setup and pairing', slug: 'getting-started/setup' },
            { label: 'Desktop installation', slug: 'getting-started/desktop' },
            { label: 'App gallery', slug: 'gallery' },
          ],
        },
        {
          label: 'Operate and understand',
          items: [
            { label: 'Relay configuration', slug: 'guides/relay' },
            { label: 'Architecture', slug: 'guides/architecture' },
            { label: 'Security and privacy', slug: 'guides/security' },
          ],
        },
        {
          label: 'Build and distribute',
          items: [
            { label: 'Development', slug: 'guides/development' },
            { label: 'Releases and app stores', slug: 'guides/releases' },
          ],
        },
        {
          label: 'Help and policies',
          items: [
            { label: 'Support', slug: 'support' },
            { label: 'Privacy information', slug: 'legal/privacy' },
            { label: 'Terms of use', slug: 'legal/terms' },
          ],
        },
      ],
    }),
  ],
});
