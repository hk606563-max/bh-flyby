/// bhtool - headless "black hole flies by Earth" pipeline for OpenSPH.
///   bhtool sim    --mass 1 --n 500000 --by 21000 --vinf 8 --end 40000 --dt 40 --out sim/
///   bhtool render --first sim/bh_0000.ssf --out frames/ --w 1920 --h 1080 [--renderer surface|volume]
#include "Sph.h"
#include "gui/MainLoop.h"
#include "gui/Settings.h"
#include "gui/jobs/CameraJobs.h"
#include "gui/jobs/RenderJobs.h"
#include "physics/Constants.h"
#include "sph/Materials.h"
#include "quantities/Attractor.h"
#include "io/FileSystem.h"
#include "io/Output.h"
#include "run/Node.h"
#include "run/jobs/GeometryJobs.h"
#include "run/jobs/InitialConditionJobs.h"
#include "run/jobs/IoJobs.h"
#include "run/jobs/MaterialJobs.h"
#include "run/jobs/ParticleJobs.h"
#include "run/jobs/SimulationJobs.h"
#include "system/Statistics.h"
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <map>
#include <string>
#include <wx/image.h>
#include <wx/init.h>
#include <wx/app.h>

using namespace Sph;

namespace {

struct Args {
    std::map<std::string, std::string> kv;
    std::string mode;
    double num(const char* k, double def) const {
        auto it = kv.find(k);
        return it == kv.end() ? def : std::atof(it->second.c_str());
    }
    std::string str(const char* k, const char* def) const {
        auto it = kv.find(k);
        return it == kv.end() ? def : it->second;
    }
};

Args parse(int argc, char** argv) {
    Args a;
    if (argc > 1) {
        a.mode = argv[1];
    }
    for (int i = 2; i + 1 < argc; i += 2) {
        std::string k = argv[i];
        if (k.rfind("--", 0) == 0) {
            k = k.substr(2);
        }
        a.kv[k] = argv[i + 1];
    }
    return a;
}

class ProgressCallbacks : public IJobCallbacks {
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    int counter = 0;

public:
    virtual void onStart(const IJob& job) override {
        std::cout << "== start: " << job.instanceName().toAscii().cstr() << std::endl;
    }
    virtual void onEnd(const Storage& storage, const Statistics&) override {
        std::cout << "== end (" << storage.getParticleCnt() << " particles)" << std::endl;
    }
    virtual void onSetUp(const Storage&, Statistics&) override {}
    virtual void onTimeStep(const Storage&, Statistics& stats) override {
        if (wxTheApp) {
            wxTheApp->ProcessPendingEvents(); // executes queued frame saves (render runs on this thread)
        }
        if (++counter % 50 != 0) {
            return;
        }
        const double wall =
            std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        double t = stats.has(StatisticsId::RUN_TIME) ? stats.get<Float>(StatisticsId::RUN_TIME) : -1;
        double dt = stats.has(StatisticsId::TIMESTEP_VALUE) ? stats.get<Float>(StatisticsId::TIMESTEP_VALUE) : -1;
        std::cout << "t=" << t << " s  dt=" << dt << " s  step=" << counter << "  wall=" << int(wall) << " s"
                  << std::endl;
    }
    virtual bool shouldAbortRun() const override {
        return false;
    }
};

const RunSettings& globals() {
    // NOTE: these are OVERRIDES applied on top of every job's own settings, so keep the list minimal
    // (a full default RunSettings here would reset run duration, output etc. of every job).
    // Built once, returned by reference (returning by value tripped over a move-ctor heisenbug).
    static RunSettings* g = nullptr;
    if (!g) {
        g = new RunSettings(EMPTY_SETTINGS);
        g->set(RunSettingsId::RUN_THREAD_CNT, 0);
        g->set(RunSettingsId::RUN_THREAD_GRANULARITY, 1000);
        g->set(RunSettingsId::RUN_RNG, RngEnum::UNIFORM);
        g->set(RunSettingsId::RUN_RNG_SEED, 1234);
        g->set(RunSettingsId::SPH_KERNEL, KernelEnum::CUBIC_SPLINE);
        g->set(RunSettingsId::GENERATE_UVWS, true); // needed for textured Earth
        g->set(RunSettingsId::UVW_MAPPING, UvMapEnum::SPHERICAL);
        g->set(RunSettingsId::FINDER_LEAF_SIZE, 25);
        g->set(RunSettingsId::FINDER_MAX_PARALLEL_DEPTH, 50);
    }
    return *g;
}

// ---------------------------------------------------------------- sim
int runSim(const Args& a) {
    const int n = int(a.num("n", 30000));
    const Float mass = a.num("mass", 1.0);         // M_earth
    const Float bhRadius = a.num("r", 200.0);      // km (visual only)
    const Float bx = a.num("bx", -150000.0);       // km
    const Float by = a.num("by", 21000.0);         // km, impact parameter
    const Float vinf = a.num("vinf", 8.0);         // km/s
    const Float endTime = a.num("end", 40000.0);   // s
    const Float interval = a.num("dt", 100.0);     // s between saved frames
    const Float maxDt = a.num("maxdt", 20.0);      // s
    const Float stabTime = a.num("stab", 1000.0);  // s
    const Path outDir(String::fromAscii(a.str("out", "sim").c_str()));
    const std::string texture = a.str("texture", "");

    // Earth: olivine mantle + iron core
    SharedPtr<JobNode> earth = makeNode<DifferentiatedBodyIc>("earth");
    {
        VirtualSettings s = earth->getSettings();
        s.set(BodySettingsId::PARTICLE_COUNT, n);
        s.set(BodySettingsId::INITIAL_DISTRIBUTION, EnumWrapper(DistributionEnum::PARAMETRIZED_SPIRALING));
        if (!texture.empty()) {
            s.set(BodySettingsId::VISUALIZATION_TEXTURE, Path(String::fromAscii(texture.c_str())));
        }
    }
    SharedPtr<JobNode> olivine = makeNode<MaterialJob>("olivine", getMaterial(MaterialEnum::OLIVINE)->getParams());
    olivine->getSettings().set(BodySettingsId::RHEOLOGY_YIELDING, EnumWrapper(YieldingEnum::DUST));
    SharedPtr<JobNode> iron = makeNode<MaterialJob>("iron", getMaterial(MaterialEnum::IRON)->getParams());
    iron->getSettings().set(BodySettingsId::RHEOLOGY_YIELDING, EnumWrapper(YieldingEnum::DUST));

    SharedPtr<JobNode> surface = makeNode<SphereJob>("surface sphere");
    surface->getSettings().set("radius", 6378._f);
    SharedPtr<JobNode> core = makeNode<SphereJob>("core sphere");
    core->getSettings().set("radius", 3480._f);

    surface->connect(earth, "base shape");
    olivine->connect(earth, "base material");
    core->connect(earth, "shape 1");
    iron->connect(earth, "material 1");

    SharedPtr<JobNode> equilibrium = makeNode<EquilibriumDensityIc>("hydrostatic equilibrium");
    earth->connect(equilibrium, "particles");

    const EnumWrapper criteria =
        EnumWrapper::fromFlags(TimeStepCriterionEnum::COURANT | TimeStepCriterionEnum::DIVERGENCE);
    const EnumWrapper forces = EnumWrapper::fromFlags(ForceEnum::PRESSURE | ForceEnum::SELF_GRAVITY);

    SharedPtr<JobNode> stab = makeNode<SphStabilizationJob>("stabilize");
    {
        VirtualSettings s = stab->getSettings();
        s.set(RunSettingsId::RUN_END_TIME, stabTime);
        s.set(RunSettingsId::SPH_SOLVER_FORCES, forces);
        s.set(RunSettingsId::TIMESTEPPING_CRITERION, criteria);
    }
    equilibrium->connect(stab, "particles");

    SharedPtr<JobNode> spin = makeNode<TransformParticlesJob>("spin");
    spin->getSettings().set("spin", 1._f); // rev/day (GUI units)
    stab->connect(spin, "particles");

    // black hole = point mass that absorbs particles
    SharedPtr<JobNode> bh = makeNode<SingleParticleIc>("black hole");
    {
        VirtualSettings s = bh->getSettings();
        s.set("mass", mass); // M_earth (GUI units)
        s.set("radius", bhRadius); // km
        s.set("r0", Vector(bx, by, 0._f)); // km
        s.set("v0", Vector(vinf, 0._f, 0._f)); // km/s
        s.set("interaction", EnumWrapper(ParticleInteractionEnum::ABSORB));
        s.set("albedo", 0._f);
    }

    SharedPtr<JobNode> join = makeNode<JoinParticlesJob>("merge");
    join->getSettings().set("com", false);
    spin->connect(join, "particles A");
    bh->connect(join, "particles B");

    const std::string resume = a.str("resume", "");
    SharedPtr<JobNode> source = join;
    if (!resume.empty()) {
        // continue from a saved state (chained jobs): load file -> SPH run with "use start time of input"
        SharedPtr<JobNode> load = makeNode<LoadFileJob>(Path(String::fromAscii(resume.c_str())));
        source = load;
        std::cout << "resuming from " << resume << std::endl;
    }

    SharedPtr<JobNode> sim = makeNode<SphJob>("flyby");
    {
        VirtualSettings s = sim->getSettings();
        s.set("is_resumed", !resume.empty());
        s.set(RunSettingsId::RUN_END_TIME, endTime);
        s.set(RunSettingsId::RUN_OUTPUT_INTERVAL, interval);
        s.set(RunSettingsId::TIMESTEPPING_MAX_TIMESTEP, maxDt);
        s.set(RunSettingsId::SPH_SOLVER_FORCES, forces);
        s.set(RunSettingsId::TIMESTEPPING_CRITERION, criteria);
        s.set(RunSettingsId::RUN_OUTPUT_TYPE, EnumWrapper(IoEnum::BINARY_FILE));
        s.set(RunSettingsId::RUN_OUTPUT_PATH, outDir);
        s.set(RunSettingsId::RUN_OUTPUT_NAME, String("bh_%d.ssf"));
    }
    source->connect(sim, "particles");

    std::cout << "sim: n=" << n << " mass=" << mass << " M_earth  b=" << by << " km  vinf=" << vinf
              << " km/s  end=" << endTime << " s  interval=" << interval << " s" << std::endl;
    ProgressCallbacks cb;
    sim->run(globals(), cb);
    return 0;
}

// ---------------------------------------------------------------- render
int runRender(const Args& a) {
    const std::string first = a.str("first", "sim/bh_0000.ssf");
    const Path outDir(String::fromAscii(a.str("out", "frames").c_str()));
    const int w = int(a.num("w", 1920));
    const int h = int(a.num("h", 1080));
    const std::string rendererName = a.str("renderer", "surface");
    const std::string quantity = a.str("quantity", "beauty");
    const Vector camPos(a.num("cx", 0), a.num("cy", -60000), a.num("cz", 15000));
    const Vector camTarget(a.num("tx", 0), a.num("ty", 0), a.num("tz", 0));
    const Float fov = a.num("fov", 35.0);
    const bool transparent = a.num("transparent", 0) > 0;
    const int extra = int(a.num("extra", 0));
    const std::string bg = a.str("bg", "");

    SharedPtr<JobNode> camera = makeNode<PerspectiveCameraJob>("camera");
    {
        VirtualSettings s = camera->getSettings();
        s.set(GuiSettingsId::CAMERA_POSITION, camPos); // km
        s.set(GuiSettingsId::CAMERA_TARGET, camTarget); // km
        s.set(GuiSettingsId::CAMERA_UP, Vector(0._f, 0._f, 1._f));
        s.set(GuiSettingsId::CAMERA_WIDTH, w);
        s.set(GuiSettingsId::CAMERA_HEIGHT, h);
        s.set(GuiSettingsId::CAMERA_PERSPECTIVE_FOV, fov); // deg
        // follow the (median) Earth position so the planet stays in frame
        s.set(GuiSettingsId::CAMERA_TRACK_MEDIAN, a.num("track", 1) > 0);
        s.set(GuiSettingsId::CAMERA_TRACKING_MOVE_CAMERA, true);
    }

    const std::string single = a.str("single", ""); // render exactly one state file
    SharedPtr<JobNode> render = makeNode<AnimationJob>("render");
    {
        VirtualSettings s = render->getSettings();
        s.set("directory", outDir);
        s.set("file_mask", String::fromAscii(a.str("mask", "frame_%d.png").c_str()));
        if (single.empty()) {
            s.set("animation_type", EnumWrapper(AnimationType::FILE_SEQUENCE));
            s.set("first_file", Path(String::fromAscii(first.c_str())));
        } else {
            s.set("animation_type", EnumWrapper(AnimationType::SINGLE_FRAME));
        }
        s.set("extra_frames", extra);
        s.set("transparent", transparent);
        RendererEnum r = RendererEnum::RAYMARCHER;
        if (rendererName == "volume") {
            r = RendererEnum::VOLUME;
        } else if (rendererName == "particle") {
            r = RendererEnum::PARTICLE;
        }
        s.set(GuiSettingsId::RENDERER, EnumWrapper(r));
        RenderColorizerId q = RenderColorizerId::BEAUTY;
        if (quantity == "energy") {
            q = RenderColorizerId::ENERGY;
        } else if (quantity == "temperature") {
            q = RenderColorizerId::TEMPERATURE;
        } else if (quantity == "velocity") {
            q = RenderColorizerId::VELOCITY;
        }
        s.set("quantity", EnumWrapper(q));
        s.set(GuiSettingsId::RAYTRACE_ITERATION_LIMIT, int(a.num("iters", 6)));
        s.set(GuiSettingsId::RAYTRACE_SHADOWS, a.num("shadows", 1) > 0);
        s.set(GuiSettingsId::SURFACE_SUN_POSITION, Vector(a.num("sx", -1), a.num("sy", -1), a.num("sz", 0.5)));
        s.set(GuiSettingsId::SURFACE_SUN_INTENSITY, Float(a.num("sun", 0.9)));
        s.set(GuiSettingsId::SURFACE_AMBIENT, Float(a.num("ambient", 0.15)));
        s.set(GuiSettingsId::SURFACE_EMISSION, Float(a.num("emission", 1.0)));
        s.set(GuiSettingsId::BLOOM_INTENSITY, Float(a.num("bloom", 0.0)));
        s.set(GuiSettingsId::SHOW_KEY, false); // no axes / scale bar overlay
        if (!bg.empty()) {
            s.set(GuiSettingsId::RAYTRACE_HDRI, Path(String::fromAscii(bg.c_str())));
        }
    }
    camera->connect(render, "camera");
    Path singlePath(String::fromAscii(single.c_str()));
    Path tmpPath;
    // Visual black hole: the physical attractor is tiny (~200 km, ABSORB radius), but on screen we want a
    // black disc of --bh_r km (reference film: 0.3 Earth radii) -> rewrite the attractor in a temp copy.
    const Float bhVisualRadius = a.num("bh_r", 0); // km, 0 = keep physical radius
    if (!single.empty() && bhVisualRadius > 0) {
        Storage storage;
        Statistics stats;
        BinaryInput input;
        Outcome ok = input.load(singlePath, storage, stats);
        if (!ok) {
            throw std::runtime_error("cannot load " + single + ": " + ok.error().toAscii().cstr());
        }
        for (Attractor& at : storage.getAttractors()) {
            at.radius = bhVisualRadius * 1.e3_f; // m
            at.settings.set(AttractorSettingsId::ALBEDO, Float(a.num("bh_albedo", 0.0)));
        }
        BinaryOutput output(OutputFile(outDir / Path("_bhtmp_%d.ssf")));
        Expected<Path> dumped = output.dump(storage, stats);
        if (!dumped) {
            throw std::runtime_error("cannot write temp state: " + std::string(dumped.error().toAscii().cstr()));
        }
        tmpPath = dumped.value();
        singlePath = tmpPath;
        std::cout << "bh visual radius " << bhVisualRadius << " km, " << storage.getAttractors().size()
                  << " attractor(s)" << std::endl;
    }
    if (!single.empty()) {
        SharedPtr<JobNode> load = makeNode<LoadFileJob>(singlePath);
        load->connect(render, "particles");
    }

    std::cout << "render: " << rendererName << "/" << quantity << " " << w << "x" << h << " from " << first
              << " -> " << outDir.string().toAscii().cstr() << std::endl;
    ProgressCallbacks cb;
    render->run(globals(), cb);
    if (!tmpPath.empty()) {
        FileSystem::removePath(tmpPath);
    }
    if (wxTheApp) {
        wxTheApp->ProcessPendingEvents();
    }
    return 0;
}

} // namespace

class BhApp : public wxApp {
public:
    virtual bool OnInit() override {
        return true;
    }
};
wxIMPLEMENT_APP_NO_MAIN(BhApp);

int main(int argc, char** argv) {
    Args a = parse(argc, argv); // parse first, wxEntryStart may touch argv
    int wxArgc = 1;
    if (!wxEntryStart(wxArgc, argv)) {
        std::cout << "FAILED: wx init (is a display / xvfb available?)" << std::endl;
        return 3;
    }
    wxTheApp->CallOnInit();
    wxInitAllImageHandlers();
    wxTheApp->Bind(MAIN_LOOP_TYPE, [](MainLoopEvent& evt) { evt.execute(); });
    int rc = 1;
    try {
        if (a.mode == "sim") {
            rc = runSim(a);
        } else if (a.mode == "render") {
            rc = runRender(a);
        } else {
            std::cout << "usage: bhtool sim|render --key value ..." << std::endl;
        }
    } catch (const Exception& e) {
        std::cout << "FAILED: " << e.what() << std::endl;
        rc = 2;
    }
    wxTheApp->ProcessPendingEvents();
    wxTheApp->OnExit();
    wxEntryCleanup();
    return rc;
}
