/**
 * THEME CONFIGURATION
 * 
 * To customize the app's colors, edit the values below.
 * These values are used to generate CSS variables in ThemeProvider.
 * 
 * HSL Format: { hue: 0-360, saturation: 0-100, lightness: 0-100 }
 */

export const themeConfig = {
  colors: {
    primary: {
      hue: 170,
      saturation: 75,
      lightness: 45,
    },
    accent: {
      hue: 200,
      saturation: 80,
      lightness: 55,
    },
    destructive: {
      hue: 0,
      saturation: 72,
      lightness: 51,
    },
    warning: {
      hue: 38,
      saturation: 92,
      lightness: 50,
    },
    success: {
      hue: 142,
      saturation: 71,
      lightness: 45,
    },
  },
  fonts: {
    sans: "Inter, system-ui, sans-serif",
    mono: "JetBrains Mono, Fira Code, monospace",
  },
  borderRadius: {
    sm: "0.25rem",
    md: "0.375rem",
    lg: "0.5rem",
  },
};

export function getThemeCssVariables() {
  const { colors } = themeConfig;
  
  return {
    "--primary": `${colors.primary.hue} ${colors.primary.saturation}% ${colors.primary.lightness}%`,
    "--ring": `${colors.primary.hue} ${colors.primary.saturation}% ${colors.primary.lightness}%`,
    "--sidebar-primary": `${colors.primary.hue} ${colors.primary.saturation}% ${colors.primary.lightness}%`,
    "--sidebar-ring": `${colors.primary.hue} ${colors.primary.saturation}% ${colors.primary.lightness}%`,
    "--chart-1": `${colors.primary.hue} ${colors.primary.saturation}% ${colors.primary.lightness + 5}%`,
    "--chart-2": `${colors.accent.hue} ${colors.accent.saturation}% ${colors.accent.lightness}%`,
    "--chart-3": `${colors.success.hue} ${colors.success.saturation}% ${colors.success.lightness}%`,
    "--chart-4": `${colors.warning.hue} ${colors.warning.saturation}% ${colors.warning.lightness}%`,
    "--chart-5": `${colors.destructive.hue} ${colors.destructive.saturation}% ${colors.destructive.lightness}%`,
    "--destructive": `${colors.destructive.hue} ${colors.destructive.saturation}% ${colors.destructive.lightness}%`,
  };
}

export function applyTheme() {
  const cssVars = getThemeCssVariables();
  const root = document.documentElement;
  
  Object.entries(cssVars).forEach(([key, value]) => {
    root.style.setProperty(key, value);
  });
}
