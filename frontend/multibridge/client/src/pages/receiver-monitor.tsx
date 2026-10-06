import { useState, useCallback } from "react";
import { Search, ExternalLink, Loader2, ArrowRight, Clock, CheckCircle, AlertCircle, XCircle, ChevronRight } from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { useToast } from "@/hooks/use-toast";
import { isValidAddress, isSolanaAddress } from "@/lib/ccip-utils";

type MessageStatus = "SENT" | "SOURCE_FINALIZED" | "COMMITTED" | "BLESSED" | "VERIFYING" | "VERIFIED" | "SUCCESS" | "FAILED";

interface NetworkInfo {
  name: string;
  chainSelector: string;
  chainId: string;
  chainFamily: "EVM" | "SVM" | "APTOS";
}

interface MessageSearchResult {
  messageId: string;
  sender: string;
  receiver: string;
  origin?: string | null;
  status: MessageStatus;
  sourceNetworkInfo: NetworkInfo;
  destNetworkInfo: NetworkInfo;
  sendTransactionHash: string;
  sendTimestamp: string;
  receiptTransactionHash?: string | null;
  receiptTimestamp?: string | null;
  sourceTokenAddress?: string | null;
}

interface MessagesResponse {
  data: MessageSearchResult[];
  pagination: {
    limit: number;
    hasNextPage: boolean;
    cursor?: string | null;
  };
}

/** Public Chainlink CCIP API (the same default the @chainlink/ccip-sdk uses). */
const CCIP_API_BASE = "https://api.ccip.chain.link/v2/";

function getStatusLabel(status: MessageStatus): string {
  switch (status) {
    case "SENT": return "Sent";
    case "SOURCE_FINALIZED": return "Source Finalized";
    case "COMMITTED": return "Committed";
    case "BLESSED": return "Blessed";
    case "VERIFYING": return "Verifying";
    case "VERIFIED": return "Verified";
    case "SUCCESS": return "Success";
    case "FAILED": return "Failed";
    default: return "Unknown";
  }
}

function getStatusIcon(status: MessageStatus) {
  switch (status) {
    case "SUCCESS":
      return <CheckCircle className="w-4 h-4 text-green-500" />;
    case "FAILED":
      return <XCircle className="w-4 h-4 text-red-500" />;
    case "SENT":
    case "SOURCE_FINALIZED":
    case "COMMITTED":
    case "BLESSED":
    case "VERIFYING":
    case "VERIFIED":
      return <Clock className="w-4 h-4 text-yellow-500" />;
    default:
      return <AlertCircle className="w-4 h-4 text-muted-foreground" />;
  }
}

function getStatusBadgeVariant(status: MessageStatus): "default" | "secondary" | "destructive" | "outline" {
  switch (status) {
    case "SUCCESS":
      return "default";
    case "FAILED":
      return "destructive";
    case "SENT":
    case "SOURCE_FINALIZED":
    case "COMMITTED":
    case "BLESSED":
    case "VERIFYING":
    case "VERIFIED":
      return "secondary";
    default:
      return "outline";
  }
}

function formatTimestamp(timestamp: string): string {
  try {
    const date = new Date(timestamp);
    return date.toLocaleString();
  } catch {
    return timestamp;
  }
}

function truncateAddress(address: string): string {
  if (!address || address.length < 10) return address;
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

function truncateHash(hash: string): string {
  if (!hash || hash.length < 16) return hash;
  return `${hash.slice(0, 10)}...${hash.slice(-6)}`;
}

export default function ReceiverMonitor() {
  const { toast } = useToast();
  const [senderAddress, setSenderAddress] = useState("");
  const [receiverAddress, setReceiverAddress] = useState("");
  const [messages, setMessages] = useState<MessageSearchResult[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [hasSearched, setHasSearched] = useState(false);
  const [pagination, setPagination] = useState<{ limit: number; hasNextPage: boolean; cursor?: string | null } | null>(null);
  const [currentCursor, setCurrentCursor] = useState<string | null>(null);

  const searchMessages = useCallback(async (cursor?: string | null) => {
    if (!senderAddress && !receiverAddress && !cursor) {
      toast({
        title: "Address required",
        description: "Please enter at least one address (sender or receiver) to search",
        variant: "destructive",
      });
      return;
    }

    if (senderAddress && !isValidAddress(senderAddress) && !isSolanaAddress(senderAddress)) {
      toast({
        title: "Invalid sender address",
        description: "Please enter a valid EVM address (0x...) or Solana address",
        variant: "destructive",
      });
      return;
    }

    if (receiverAddress && !isValidAddress(receiverAddress) && !isSolanaAddress(receiverAddress)) {
      toast({
        title: "Invalid receiver address",
        description: "Please enter a valid EVM address (0x...) or Solana address",
        variant: "destructive",
      });
      return;
    }

    setIsLoading(true);
    if (!cursor) {
      setHasSearched(true);
      setCurrentCursor(null);
    }

    try {
      const params = new URLSearchParams();
      
      if (cursor) {
        // Pagination mode - only cursor and limit
        params.set("cursor", cursor);
        params.set("limit", "50");
      } else {
        // Filter mode - use address filters
        params.set("limit", "50");
        if (senderAddress) {
          params.set("sender", senderAddress);
        }
        if (receiverAddress) {
          params.set("receiver", receiverAddress);
        }
      }
      
      const url = `${CCIP_API_BASE}messages?${params.toString()}`;
      const response = await fetch(url, {
        headers: {
          "Accept": "application/json",
        },
      });
      
      const contentType = response.headers.get("content-type") || "";
      const isJson = contentType.includes("application/json");
      
      if (!response.ok) {
        let errorData: any = { error: "Unknown error", message: `API error: ${response.status}` };
        if (isJson) {
          try {
            errorData = await response.json();
          } catch (e) {
            console.error("Failed to parse error response:", e);
            errorData = { 
              error: `HTTP ${response.status}`,
              message: `Server returned ${response.status} ${response.statusText}`
            };
          }
        } else {
          const text = await response.text();
          console.error("Non-JSON error response:", text.substring(0, 200));
          errorData = { 
            error: `HTTP ${response.status}`,
            message: `Server returned ${response.status} ${response.statusText}. Please check the server logs.`
          };
        }
        throw new Error(errorData.message || errorData.error || `API error: ${response.status}`);
      }

      if (!isJson) {
        const text = await response.text();
        console.error("Non-JSON response received:", text.substring(0, 200));
        throw new Error("Server returned invalid response format. Expected JSON.");
      }

      const data: MessagesResponse = await response.json();
      
      if (cursor) {
        // Append to existing messages for pagination
        setMessages(prev => [...prev, ...(data.data || [])]);
      } else {
        // Replace messages for new search
        setMessages(data.data || []);
      }
      
      setPagination(data.pagination);
      setCurrentCursor(data.pagination.cursor || null);

      if (!cursor && data.data?.length === 0) {
        const searchDesc = senderAddress && receiverAddress 
          ? `sender ${senderAddress.slice(0, 10)}... and receiver ${receiverAddress.slice(0, 10)}...`
          : senderAddress 
          ? `sender ${senderAddress.slice(0, 10)}...`
          : `receiver ${receiverAddress.slice(0, 10)}...`;
        toast({
          title: "No messages found",
          description: `No CCIP messages found for ${searchDesc}`,
        });
      }
    } catch (error) {
      console.error("Error fetching messages:", error);
      toast({
        title: "Error",
        description: error instanceof Error ? error.message : "Failed to fetch messages. Please try again.",
        variant: "destructive",
      });
      if (!cursor) {
        setMessages([]);
      }
    } finally {
      setIsLoading(false);
    }
  }, [senderAddress, receiverAddress, toast]);

  const loadMore = useCallback(() => {
    if (currentCursor && pagination?.hasNextPage) {
      searchMessages(currentCursor);
    }
  }, [currentCursor, pagination, searchMessages]);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter") {
      searchMessages();
    }
  };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Receiver Monitor</h1>
        <p className="text-muted-foreground mt-1">
          Search and monitor CCIP cross-chain messages by sender address, receiver address, or both
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Search Messages</CardTitle>
          <CardDescription>
            Enter sender and/or receiver addresses to find CCIP messages. Both fields are optional.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div className="flex-1">
              <Label htmlFor="senderAddress">From (Sender)</Label>
              <Input
                id="senderAddress"
                placeholder="0x... or Solana address (optional)"
                value={senderAddress}
                onChange={(e) => setSenderAddress(e.target.value)}
                onKeyDown={handleKeyDown}
                className="font-mono"
                data-testid="input-search-sender"
              />
            </div>
            <div className="flex-1">
              <Label htmlFor="receiverAddress">To (Receiver)</Label>
              <Input
                id="receiverAddress"
                placeholder="0x... or Solana address (optional)"
                value={receiverAddress}
                onChange={(e) => setReceiverAddress(e.target.value)}
                onKeyDown={handleKeyDown}
                className="font-mono"
                data-testid="input-search-receiver"
              />
            </div>
          </div>
          <div className="flex items-center gap-2">
            <Button 
              onClick={() => searchMessages()} 
              disabled={isLoading || (!senderAddress && !receiverAddress)}
              className="w-full sm:w-auto"
              data-testid="button-search"
            >
              {isLoading ? (
                <>
                  <Loader2 className="w-4 h-4 mr-2 animate-spin" />
                  Searching...
                </>
              ) : (
                <>
                  <Search className="w-4 h-4 mr-2" />
                  Search Messages
                </>
              )}
            </Button>
            {(senderAddress || receiverAddress) && (
              <Button
                variant="outline"
                onClick={() => {
                  setSenderAddress("");
                  setReceiverAddress("");
                  setMessages([]);
                  setHasSearched(false);
                  setPagination(null);
                  setCurrentCursor(null);
                }}
                disabled={isLoading}
                data-testid="button-clear"
              >
                Clear
              </Button>
            )}
          </div>
        </CardContent>
      </Card>

      {hasSearched && (
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center justify-between gap-2">
              <span>Results</span>
              {messages.length > 0 && (
                <Badge variant="secondary" className="font-mono">
                  {messages.length} message{messages.length !== 1 ? "s" : ""}
                  {pagination?.hasNextPage && " (more available)"}
                </Badge>
              )}
            </CardTitle>
          </CardHeader>
          <CardContent>
            {isLoading && messages.length === 0 ? (
              <div className="flex items-center justify-center py-12">
                <Loader2 className="w-8 h-8 animate-spin text-muted-foreground" />
              </div>
            ) : messages.length === 0 ? (
              <div className="text-center py-12 text-muted-foreground">
                <AlertCircle className="w-12 h-12 mx-auto mb-4 opacity-50" />
                <p>No messages found for this address</p>
              </div>
            ) : (
              <div className="space-y-4">
                {messages.map((msg) => (
                  <div
                    key={msg.messageId}
                    className="border rounded-lg p-4 space-y-3"
                    data-testid={`msg-${msg.messageId}`}
                  >
                    <div className="flex items-center justify-between gap-2 flex-wrap">
                      <div className="flex items-center gap-2">
                        {getStatusIcon(msg.status)}
                        <Badge variant={getStatusBadgeVariant(msg.status)}>
                          {getStatusLabel(msg.status)}
                        </Badge>
                        <span className="text-xs text-muted-foreground">
                          {formatTimestamp(msg.sendTimestamp)}
                        </span>
                        {msg.receiptTimestamp && (
                          <span className="text-xs text-muted-foreground">
                            • Executed: {formatTimestamp(msg.receiptTimestamp)}
                          </span>
                        )}
                      </div>
                      <div className="flex items-center gap-2 text-sm">
                        <Badge variant="outline" className="font-mono text-xs">
                          {msg.sourceNetworkInfo.name}
                        </Badge>
                        <ArrowRight className="w-4 h-4 text-muted-foreground" />
                        <Badge variant="outline" className="font-mono text-xs">
                          {msg.destNetworkInfo.name}
                        </Badge>
                      </div>
                    </div>

                    <div className="grid grid-cols-1 md:grid-cols-2 gap-3 text-sm">
                      <div>
                        <span className="text-muted-foreground">Message ID:</span>
                        <span className="font-mono ml-2">{truncateHash(msg.messageId)}</span>
                      </div>
                      <div>
                        <span className="text-muted-foreground">Sender:</span>
                        <span className="font-mono ml-2">{truncateAddress(msg.sender)}</span>
                      </div>
                      <div>
                        <span className="text-muted-foreground">Receiver:</span>
                        <span className="font-mono ml-2">{truncateAddress(msg.receiver)}</span>
                      </div>
                      {msg.sendTransactionHash && (
                        <div>
                          <span className="text-muted-foreground">Source Tx:</span>
                          <a
                            href={`https://ccip.chain.link/msg/${msg.messageId}`}
                            target="_blank"
                            rel="noopener noreferrer"
                            className="font-mono ml-2 text-primary hover:underline inline-flex items-center gap-1"
                          >
                            {truncateHash(msg.sendTransactionHash)}
                            <ExternalLink className="w-3 h-3" />
                          </a>
                        </div>
                      )}
                      {msg.receiptTransactionHash && (
                        <div>
                          <span className="text-muted-foreground">Dest Tx:</span>
                          <span className="font-mono ml-2">{truncateHash(msg.receiptTransactionHash)}</span>
                        </div>
                      )}
                    </div>

                    {msg.sourceTokenAddress && (
                      <div className="pt-2 border-t">
                        <span className="text-sm text-muted-foreground">Token Transfer:</span>
                        <Badge variant="secondary" className="font-mono text-xs ml-2">
                          {truncateAddress(msg.sourceTokenAddress)}
                        </Badge>
                      </div>
                    )}

                    <div className="pt-2 flex justify-end">
                      <Button
                        variant="ghost"
                        size="sm"
                        asChild
                        data-testid={`button-view-${msg.messageId}`}
                      >
                        <a
                          href={`https://ccip.chain.link/msg/${msg.messageId}`}
                          target="_blank"
                          rel="noopener noreferrer"
                        >
                          View on CCIP Explorer
                          <ExternalLink className="w-4 h-4 ml-2" />
                        </a>
                      </Button>
                    </div>
                  </div>
                ))}
                
                {pagination?.hasNextPage && (
                  <div className="pt-4 border-t flex justify-center">
                    <Button
                      variant="outline"
                      onClick={loadMore}
                      disabled={isLoading}
                      data-testid="button-load-more"
                    >
                      {isLoading ? (
                        <>
                          <Loader2 className="w-4 h-4 mr-2 animate-spin" />
                          Loading...
                        </>
                      ) : (
                        <>
                          Load More
                          <ChevronRight className="w-4 h-4 ml-2" />
                        </>
                      )}
                    </Button>
                  </div>
                )}
              </div>
            )}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
