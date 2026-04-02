import { Nav } from "@/components/shared/nav";
import { Footer } from "@/components/shared/footer";
import { Hero } from "@/components/hero";
import { Stats } from "@/components/stats";
import { Features } from "@/components/features";
import { Pipeline } from "@/components/pipeline";
import { Integrations } from "@/components/integrations";
import { Cta } from "@/components/cta";
import { VoiceDemoLoader } from "@/components/voice-demo-loader";

const NAV_LINKS = [
  { label: "Features", href: "#features" },
  { label: "Demo", href: "#demo" },
  { label: "Setup", href: "#setup" },
  { label: "Docs", href: "https://etanhey.github.io/voicelayer/docs/" },
];

function Divider() {
  return (
    <div className="mx-auto max-w-[960px] px-6">
      <div className="h-px bg-gradient-to-r from-transparent via-border to-transparent" />
    </div>
  );
}

export default function Home() {
  return (
    <>
      <Nav
        product="voicelayer"
        links={NAV_LINKS}
        githubUrl="https://github.com/EtanHey/voicelayer"
      />
      <Hero />
      <Stats />
      <Features />
      <Pipeline />
      <VoiceDemoLoader />
      <Divider />
      <Integrations />
      <Cta />
      <Footer product="voicelayer" />
    </>
  );
}
