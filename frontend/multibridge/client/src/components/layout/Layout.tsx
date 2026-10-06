import { Link, useLocation } from "wouter";
import { 
  Vault,
  Radio, 
  Menu,
  ShieldCheck,
  Hexagon
} from "lucide-react";
import { Sheet, SheetContent, SheetTrigger } from "@/components/ui/sheet";
import { Button } from "@/components/ui/button";
import { useState, type ReactNode } from "react";
import { NetworkWarning } from "@/components/ConnectionStatus";
import { ErrorBoundary } from "@/components/ErrorBoundary";

interface LayoutProps {
  children: ReactNode;
}

export function Layout({ children }: LayoutProps) {
  const [location] = useLocation();
  const [isMobileOpen, setIsMobileOpen] = useState(false);

  const navItems = [
    { label: "Vault Dashboard", icon: Vault, href: "/" },
    { label: "Message Monitor", icon: Radio, href: "/monitor" },
  ];

  const NavContent = ({ onNavigate }: { onNavigate?: () => void }) => (
    <div className="flex flex-col h-full bg-sidebar text-sidebar-foreground border-r border-sidebar-border">
      <div className="p-6 flex items-center gap-3 border-b border-sidebar-border/50 h-16">
        <div className="relative flex items-center justify-center w-8 h-8 rounded-lg bg-primary text-primary-foreground shadow-lg shadow-primary/20">
          <Hexagon className="w-5 h-5 fill-current" />
          <div className="absolute inset-0 bg-primary/20 blur-lg rounded-full" />
        </div>
        <div>
          <h1 className="font-display font-bold text-lg tracking-tight leading-none">Vault Sender</h1>
          <span className="text-[10px] text-muted-foreground font-mono font-medium tracking-wider">CCIP · LZ · Stargate</span>
        </div>
      </div>

      <nav className="flex-1 p-4 space-y-1">
        {navItems.map((item) => {
          const isActive = location === item.href || (location === '/' && item.href === '/');
          return (
            <Link key={item.href} href={item.href} onClick={onNavigate}>
              <div
                data-testid={`nav-${item.label.toLowerCase().replace(/\s+/g, '-')}`}
                className={`flex items-center gap-3 px-4 py-3 rounded-md text-sm font-medium transition-all duration-200 cursor-pointer group ${
                  isActive
                    ? "bg-sidebar-accent text-sidebar-accent-foreground shadow-sm border border-sidebar-border/50"
                    : "text-muted-foreground hover:bg-sidebar-accent/50 hover:text-foreground border border-transparent"
                }`}
              >
                <item.icon className={`w-4 h-4 transition-colors ${isActive ? "text-primary" : "text-muted-foreground group-hover:text-foreground"}`} />
                {item.label}
              </div>
            </Link>
          );
        })}
      </nav>

      <div className="p-4 mt-auto border-t border-sidebar-border/50">
        <div className="bg-sidebar-accent/30 rounded-lg p-4 border border-sidebar-border/50 backdrop-blur-sm">
          <div className="flex items-center gap-2 mb-2">
            <ShieldCheck className="w-4 h-4 text-primary" />
            <span className="text-xs font-semibold text-foreground">Reference implementation</span>
          </div>
          <p className="text-[10px] text-muted-foreground leading-relaxed">
            Example app for testing and integration. Not audited; not for production use.
          </p>
        </div>
      </div>
    </div>
  );

  return (
    <div className="min-h-screen bg-background font-sans flex">
      {/* Desktop Sidebar */}
      <aside className="hidden md:block w-64 fixed inset-y-0 left-0 z-50 bg-background/50 backdrop-blur-xl">
        <NavContent onNavigate={undefined} />
      </aside>

      {/* Main Content */}
      <div className="flex-1 md:ml-64 min-h-screen relative flex flex-col">
        {/* Header */}
        <header className="sticky top-0 z-40 h-16 border-b border-border bg-background/80 backdrop-blur-md px-6 flex items-center justify-between">
          <div className="flex items-center gap-4 md:hidden">
            <Sheet open={isMobileOpen} onOpenChange={setIsMobileOpen}>
              <SheetTrigger asChild>
                <Button variant="ghost" size="icon" className="-ml-2" data-testid="button-mobile-menu">
                  <Menu className="w-5 h-5" />
                </Button>
              </SheetTrigger>
              <SheetContent side="left" className="p-0 w-64 border-r-0">
                <NavContent onNavigate={() => setIsMobileOpen(false)} />
              </SheetContent>
            </Sheet>
            <span className="font-display font-bold text-lg">Vault Sender</span>
          </div>

          <div className="hidden md:flex items-center text-sm text-muted-foreground">
            <span className="flex items-center gap-2">
              <span className="w-2 h-2 rounded-full bg-green-500 animate-pulse"></span>
              CCIP Active
            </span>
          </div>

          <div className="flex items-center gap-4">
            {/* Reown AppKit wallet button */}
            <appkit-button />
          </div>
        </header>

        {/* Network Warning */}
        <div className="px-4 md:px-8">
          <NetworkWarning />
        </div>

        <main className="flex-1 p-4 md:p-8 max-w-7xl mx-auto w-full space-y-8">
          <ErrorBoundary>
            {children}
          </ErrorBoundary>
        </main>
      </div>
    </div>
  );
}
