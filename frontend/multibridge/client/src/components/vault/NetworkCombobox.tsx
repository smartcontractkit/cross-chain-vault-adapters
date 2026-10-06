import { useState } from "react";
import { Check, ChevronsUpDown } from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Badge } from "@/components/ui/badge";
import { HUB_CHAINS } from "@/lib/adapter/networks";

interface Props {
  value?: number;
  onChange: (chainId: number) => void;
  placeholder?: string;
}

export function NetworkCombobox({ value, onChange, placeholder = "Select hub network" }: Props) {
  const [open, setOpen] = useState(false);
  const selected = HUB_CHAINS.find((c) => c.id === value);

  const testnets = HUB_CHAINS.filter((c) => c.isTestnet);
  const mainnets = HUB_CHAINS.filter((c) => !c.isTestnet);

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          variant="outline"
          role="combobox"
          aria-expanded={open}
          className="w-full justify-between font-normal"
          data-testid="select-hub-network"
        >
          {selected ? (
            <span className="flex items-center gap-2">
              {selected.name}
              <Badge variant={selected.isTestnet ? "secondary" : "outline"} className="text-[10px]">
                {selected.isTestnet ? "testnet" : "mainnet"}
              </Badge>
            </span>
          ) : (
            <span className="text-muted-foreground">{placeholder}</span>
          )}
          <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-[--radix-popover-trigger-width] p-0" align="start">
        <Command
          filter={(itemValue, search) => (itemValue.toLowerCase().includes(search.toLowerCase()) ? 1 : 0)}
        >
          <CommandInput placeholder="Search network..." />
          <CommandList>
            <CommandEmpty>No network found.</CommandEmpty>
            <CommandGroup heading="Testnets">
              {testnets.map((c) => (
                <CommandItem
                  key={c.id}
                  value={`${c.name} ${c.id}`}
                  onSelect={() => {
                    onChange(c.id);
                    setOpen(false);
                  }}
                >
                  <Check className={cn("mr-2 h-4 w-4", value === c.id ? "opacity-100" : "opacity-0")} />
                  {c.name}
                  <span className="ml-auto text-xs text-muted-foreground">{c.id}</span>
                </CommandItem>
              ))}
            </CommandGroup>
            <CommandGroup heading="Mainnets">
              {mainnets.map((c) => (
                <CommandItem
                  key={c.id}
                  value={`${c.name} ${c.id}`}
                  onSelect={() => {
                    onChange(c.id);
                    setOpen(false);
                  }}
                >
                  <Check className={cn("mr-2 h-4 w-4", value === c.id ? "opacity-100" : "opacity-0")} />
                  {c.name}
                  <span className="ml-auto text-xs text-muted-foreground">{c.id}</span>
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
